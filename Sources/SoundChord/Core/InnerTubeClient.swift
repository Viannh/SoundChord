import CryptoKit
import Foundation

// MARK: - InnerTube Client (YouTube Music WEB_REMIX)

public final class InnerTubeClient: InnerTubeServiceProtocol, Sendable {
    private static let musicBaseURL = "https://music.youtube.com/youtubei/v1"
    private static let musicOrigin = "https://music.youtube.com"
    private static let clientName = "WEB_REMIX"
    private static let clientId = "67"
    private static let defaultClientVersion = "1.20260707.12.00"
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
    private static let visitorDataDefaultsKey = "BitChord.InnerTube.visitorData"

    private let session: URLSession
    private let state: SessionState

    private actor SessionState {
        var cookie: String?
        var visitorData: String?
        var clientVersion: String = InnerTubeClient.defaultClientVersion

        init() {
            let stored = UserDefaults.standard.string(forKey: InnerTubeClient.visitorDataDefaultsKey)
            if let stored, !stored.isEmpty {
                self.visitorData = stored
            }
        }

        func setCookie(_ newCookie: String?) {
            let trimmed = newCookie?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
            if self.cookie != normalized {
                self.cookie = normalized
                self.visitorData = nil
                UserDefaults.standard.removeObject(forKey: InnerTubeClient.visitorDataDefaultsKey)
            }
        }

        func updateVisitorData(_ value: String?) {
            guard let value, !value.isEmpty, value != visitorData else { return }
            self.visitorData = value
            UserDefaults.standard.set(value, forKey: InnerTubeClient.visitorDataDefaultsKey)
        }

        func snapshot() -> (cookie: String?, visitorData: String?, clientVersion: String) {
            (cookie, visitorData, clientVersion)
        }
    }

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config)
        self.state = SessionState()
    }

    // MARK: - InnerTubeServiceProtocol

    public func setCookie(_ cookie: String?) async {
        await state.setCookie(cookie)
    }

    public func fetchHome() async throws -> [ShelfSection] {
        let json = try await post(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        var shelves = InnerTubeParser.parseShelves(from: json)
        // Optionally fetch one continuation page if the first page is sparse.
        if shelves.count < 4, let token = InnerTubeParser.continuationToken(from: json) {
            if let nextPage = try? await postContinuation(endpoint: "browse", token: token) {
                let more = InnerTubeParser.parseContinuationShelves(from: nextPage)
                let existingTitles = Set(shelves.map { $0.title.lowercased() })
                for shelf in more where !existingTitles.contains(shelf.title.lowercased()) {
                    shelves.append(shelf)
                }
            }
        }
        return shelves
    }

    public func fetchExplore() async throws -> [ShelfSection] {
        let json = try await post(endpoint: "browse", body: ["browseId": "FEmusic_explore"])
        var shelves = InnerTubeParser.parseShelves(from: json)
        // Also collect any mood/genre grids that appear on Explore.
        let moodSections = InnerTubeParser.parseNavigationGridShelves(from: json)
        if !moodSections.isEmpty {
            let existing = Set(shelves.map { $0.title.lowercased() })
            for section in moodSections where !existing.contains(section.title.lowercased()) {
                shelves.append(section)
            }
        }
        return shelves
    }

    public func fetchSearchSuggestions(query: String) async throws -> [SearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let json = try await post(endpoint: "music/get_search_suggestions", body: ["input": trimmed])
        return InnerTubeParser.parseSearchSuggestions(from: json)
    }

    public func search(query: String) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults(query: trimmed) }
        let json = try await post(endpoint: "search", body: ["query": trimmed])
        return InnerTubeParser.parseSearchResults(query: trimmed, from: json)
    }

    public func fetchAlbum(browseId: String) async throws -> Album {
        let json = try await post(endpoint: "browse", body: ["browseId": browseId])
        var album = InnerTubeParser.parseAlbum(browseId: browseId, from: json)
        // If the album browse page returned no tracks but exposed its backing playlistId, load it.
        if album.tracks.isEmpty, let playlistId = album.playlistId, !playlistId.isEmpty {
            let plBrowseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
            if let plJson = try? await post(endpoint: "browse", body: ["browseId": plBrowseId]) {
                let fallbackPlaylist = InnerTubeParser.parsePlaylist(browseId: plBrowseId, from: plJson)
                if !fallbackPlaylist.tracks.isEmpty {
                    album.tracks = fallbackPlaylist.tracks.map { track in
                        var copy = track
                        if copy.album == nil { copy.album = album.title }
                        if copy.albumId == nil { copy.albumId = album.id }
                        if copy.artworkURL == nil { copy.artworkURL = album.artworkURL }
                        return copy
                    }
                }
            }
        }
        return album
    }

    public func fetchArtist(browseId: String) async throws -> Artist {
        let json = try await post(endpoint: "browse", body: ["browseId": browseId])
        return InnerTubeParser.parseArtist(browseId: browseId, from: json)
    }

    public func fetchPlaylist(browseId: String) async throws -> Playlist {
        let normalizedId = Self.normalizedPlaylistBrowseId(browseId)
        let json = try await post(endpoint: "browse", body: ["browseId": normalizedId])
        var playlist = InnerTubeParser.parsePlaylist(browseId: browseId, from: json)

        // Follow up to 2 continuation pages so large playlists load more than the first batch.
        var continuation = InnerTubeParser.playlistContinuationToken(from: json)
        var pagesFetched = 0
        var seenIds = Set(playlist.tracks.map(\.videoId))
        while let token = continuation, pagesFetched < 2 {
            pagesFetched += 1
            guard let nextJson = try? await postContinuation(endpoint: "browse", token: token) else { break }
            let moreTracks = InnerTubeParser.parsePlaylistContinuationTracks(from: nextJson)
            if moreTracks.isEmpty { break }
            for track in moreTracks where seenIds.insert(track.videoId).inserted {
                playlist.tracks.append(track)
            }
            continuation = InnerTubeParser.playlistContinuationToken(from: nextJson)
        }
        return playlist
    }

    public func fetchUpNextRadio(videoId: String) async throws -> [Track] {
        guard !videoId.isEmpty else { return [] }
        let json = try await post(
            endpoint: "next",
            body: [
                "videoId": videoId,
                "playlistId": "RDAMVM\(videoId)",
                "isAudioOnly": true
            ]
        )
        return InnerTubeParser.parseWatchQueue(from: json)
    }

    // MARK: - Internal Helpers for LyricsEngine

    internal func fetchLyricsFromWatchPage(videoId: String) async -> String? {
        guard !videoId.isEmpty else { return nil }
        guard let nextJson = try? await post(
            endpoint: "next",
            body: [
                "videoId": videoId,
                "playlistId": "RDAMVM\(videoId)",
                "isAudioOnly": true
            ]
        ) else {
            return nil
        }

        let tabs = InnerTubeParser.collectRenderers(in: nextJson, named: "tabRenderer")
        let lyricsEndpoint: [String: Any]? = {
            if let named = tabs.first(where: { tab in
                let title = (tab["title"] as? String) ?? ""
                return title.caseInsensitiveCompare("Lyrics") == .orderedSame
            }) {
                return InnerTubeParser.collectRenderers(in: named, named: "browseEndpoint").first
            }
            if tabs.count > 1 {
                for tab in tabs.dropFirst() {
                    if let endpoint = InnerTubeParser.collectRenderers(in: tab, named: "browseEndpoint").first,
                       let browseId = endpoint["browseId"] as? String,
                       browseId.hasPrefix("MPLY") {
                        return endpoint
                    }
                }
            }
            return nil
        }()

        guard let browseId = lyricsEndpoint?["browseId"] as? String, !browseId.isEmpty else {
            return nil
        }

        var body: [String: Any] = ["browseId": browseId]
        if let params = lyricsEndpoint?["params"] as? String, !params.isEmpty {
            body["params"] = params
        }

        guard let page = try? await post(endpoint: "browse", body: body) else {
            return nil
        }

        guard let shelf = InnerTubeParser.collectRenderers(in: page, named: "musicDescriptionShelfRenderer").first else {
            return nil
        }
        let text = InnerTubeParser.runsText(shelf["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    internal func fetchTranscriptCues(videoId: String) async -> [(startTime: TimeInterval, text: String)]? {
        guard !videoId.isEmpty else { return nil }
        let idBytes = Array(videoId.utf8)
        guard idBytes.count < 128 else { return nil }
        var proto = Data([0x0A, UInt8(idBytes.count)])
        proto.append(contentsOf: idBytes)
        let params = proto.base64EncodedString()

        guard let json = try? await post(endpoint: "get_transcript", body: ["params": params]) else {
            return nil
        }

        let cues = InnerTubeParser.collectRenderers(in: json, named: "transcriptCueRenderer")
        var result: [(TimeInterval, String)] = []
        for cue in cues {
            let offsetMs: Double?
            if let str = cue["startOffsetMs"] as? String, let val = Double(str) {
                offsetMs = val
            } else if let num = cue["startOffsetMs"] as? NSNumber {
                offsetMs = num.doubleValue
            } else {
                offsetMs = nil
            }
            guard let ms = offsetMs else { continue }
            let rawText = InnerTubeParser.runsText(cue["cue"])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "♪")))
            if !rawText.isEmpty {
                result.append((ms / 1000.0, rawText))
            }
        }
        result.sort { $0.0 < $1.0 }
        return result.isEmpty ? nil : result
    }

    // MARK: - Networking & Auth

    private func ensureVisitorData() async -> String? {
        if let existing = await state.snapshot().visitorData {
            return existing
        }
        guard let url = URL(string: "https://www.youtube.com/sw.js_data") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let match = text.range(of: #"Cg[A-Za-z0-9_%-]{40,}"#, options: .regularExpression) {
            let visitor = String(text[match])
            await state.updateVisitorData(visitor)
            return visitor
        }
        return nil
    }

    private func post(
        endpoint: String,
        body: [String: Any],
        queryItems: [URLQueryItem] = []
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "\(Self.musicBaseURL)/\(endpoint)")
        var items = [URLQueryItem(name: "prettyPrint", value: "false")]
        items.append(contentsOf: queryItems)
        components?.queryItems = items
        guard let url = components?.url else {
            throw BitChordError.invalidURL
        }

        _ = await ensureVisitorData()
        let snap = await state.snapshot()

        var clientContext: [String: Any] = [
            "clientName": Self.clientName,
            "clientVersion": snap.clientVersion,
            "hl": Self.currentLanguageCode(),
            "gl": Self.currentRegionCode(),
            "platform": "DESKTOP",
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60
        ]
        if let visitorData = snap.visitorData {
            clientContext["visitorData"] = visitorData
        }

        var payload = body
        payload["context"] = [
            "client": clientContext,
            "user": ["lockedSafetyMode": false]
        ]

        let requestBody: Data
        do {
            requestBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            throw BitChordError.parseError("Could not encode InnerTube request: \(error.localizedDescription)")
        }

        var lastError: Error = BitChordError.networkFailure("Request failed")
        for attempt in 0..<3 {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
            request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
            request.setValue(Self.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(snap.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            request.setValue("\(Self.currentLanguageCode()),en;q=0.9", forHTTPHeaderField: "Accept-Language")

            if let visitorData = snap.visitorData {
                request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            }

            if let cookie = snap.cookie, !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                if let sapisid = Self.extractSAPISID(from: cookie) {
                    let auth = Self.sapisidHashHeader(sapisid: sapisid, origin: Self.musicOrigin)
                    request.setValue(auth, forHTTPHeaderField: "Authorization")
                }
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BitChordError.networkFailure("Invalid HTTP response")
                }

                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    let detail = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    lastError = BitChordError.httpError(http.statusCode, detail)
                    if attempt < 2 {
                        let delayNs = UInt64(500_000_000) * UInt64(1 << attempt)
                        try await Task.sleep(nanoseconds: delayNs)
                        continue
                    }
                    throw lastError
                }

                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw BitChordError.httpError(http.statusCode, "YouTube Music rejected the request.")
                    }
                    let detail = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    throw BitChordError.httpError(http.statusCode, detail)
                }

                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw BitChordError.parseError("Expected JSON object from \(endpoint)")
                }

                if let responseContext = parsed["responseContext"] as? [String: Any],
                   let newVisitor = responseContext["visitorData"] as? String,
                   !newVisitor.isEmpty {
                    await state.updateVisitorData(newVisitor)
                }

                return parsed
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BitChordError {
                throw error
            } catch {
                lastError = BitChordError.networkFailure(error.localizedDescription)
                if attempt < 2 {
                    let delayNs = UInt64(400_000_000) * UInt64(1 << attempt)
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
            }
        }

        throw lastError
    }

    private func postContinuation(endpoint: String, token: String) async throws -> [String: Any] {
        try await post(
            endpoint: endpoint,
            body: ["continuation": token],
            queryItems: [
                URLQueryItem(name: "ctoken", value: token),
                URLQueryItem(name: "continuation", value: token),
                URLQueryItem(name: "type", value: "next")
            ]
        )
    }

    // MARK: - Auth Helpers

    internal static func extractSAPISID(from cookieHeader: String) -> String? {
        let pairs = cookieHeader.split(separator: ";")
        var map: [String: String] = [:]
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty {
                map[key] = val
            }
        }
        return map["SAPISID"] ?? map["__Secure-3PAPISID"] ?? map["__Secure-1PAPISID"]
    }

    internal static func sapisidHashHeader(sapisid: String, origin: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let raw = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    private static func normalizedPlaylistBrowseId(_ browseId: String) -> String {
        if browseId.hasPrefix("VL") || browseId.hasPrefix("FE") || browseId.hasPrefix("MPRE") {
            return browseId
        }
        if browseId.hasPrefix("PL") || browseId.hasPrefix("RD") || browseId.hasPrefix("OLAK") || browseId == "LM" {
            return "VL\(browseId)"
        }
        return browseId
    }

    private static func currentLanguageCode() -> String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static func currentRegionCode() -> String {
        Locale.current.region?.identifier ?? "US"
    }
}

// MARK: - InnerTube JSON Parser

internal enum InnerTubeParser {
    private static let typeWords: Set<String> = [
        "song", "video", "album", "single", "ep", "artist", "playlist", "podcast", "episode"
    ]
    private static let releaseWords: Set<String> = ["album", "single", "ep"]
    private static let headerRendererKeys = [
        "musicResponsiveHeaderRenderer",
        "musicDetailHeaderRenderer"
    ]

    // MARK: - Shelves (Home & Explore)

    static func parseShelves(from root: [String: Any]) -> [ShelfSection] {
        let tabs = (root["contents"] as? [String: Any])?["singleColumnBrowseResultsRenderer"]
            .flatMap { ($0 as? [String: Any])?["tabs"] as? [[String: Any]] } ?? []

        let sectionList = tabs.first?["tabRenderer"]
            .flatMap { ($0 as? [String: Any])?["content"] as? [String: Any] }?["sectionListRenderer"]
            .flatMap { ($0 as? [String: Any])?["contents"] as? [[String: Any]] } ?? []

        var sections: [ShelfSection] = []
        for entry in sectionList {
            if let carousel = entry["musicCarouselShelfRenderer"] as? [String: Any],
               let section = parseCarouselShelf(carousel) {
                sections.append(section)
            } else if let shelf = entry["musicShelfRenderer"] as? [String: Any],
                      let section = parsePlainShelf(shelf) {
                sections.append(section)
            }
        }
        return sections
    }

    static func parseContinuationShelves(from root: [String: Any]) -> [ShelfSection] {
        var sections: [ShelfSection] = []
        for carousel in collectRenderers(in: root, named: "musicCarouselShelfRenderer") {
            if let section = parseCarouselShelf(carousel) {
                sections.append(section)
            }
        }
        for shelf in collectRenderers(in: root, named: "musicShelfRenderer") {
            if let section = parsePlainShelf(shelf) {
                sections.append(section)
            }
        }
        return sections
    }

    static func parseNavigationGridShelves(from root: [String: Any]) -> [ShelfSection] {
        var sections: [ShelfSection] = []
        for grid in collectRenderers(in: root, named: "gridRenderer") {
            let header = (grid["header"] as? [String: Any])?["gridHeaderRenderer"] as? [String: Any]
            let title = runsText(header?["title"])
            guard let itemsRaw = grid["items"] as? [[String: Any]] else { continue }

            var items: [ShelfItem] = []
            for item in itemsRaw {
                if let twoRow = item["musicTwoRowItemRenderer"] as? [String: Any],
                   let parsed = parseTwoRowItem(twoRow) {
                    items.append(parsed)
                } else if let btn = item["musicNavigationButtonRenderer"] as? [String: Any] {
                    let label = runsText(btn["buttonText"])
                    let endpoint = ((btn["clickCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any])
                        ?? ((btn["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])
                    if !label.isEmpty, let browseId = endpoint?["browseId"] as? String {
                        items.append(.playlist(Playlist(id: browseId, title: label, author: "Mood & Genre")))
                    }
                }
            }
            if !items.isEmpty {
                let isButtons = itemsRaw.first?["musicNavigationButtonRenderer"] != nil
                sections.append(ShelfSection(
                    id: "grid:\(title):\(sections.count)",
                    title: title.isEmpty ? "Moods & Genres" : title,
                    style: isButtons ? .moodChips : .squareGrid,
                    items: items
                ))
            }
        }
        return sections
    }

    private static func parseCarouselShelf(_ carousel: [String: Any]) -> ShelfSection? {
        let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        let title = runsText(header?["title"])
        let strapline = runsText(header?["strapline"])
        let moreBrowseId = extractMoreBrowseId(from: header)

        guard let contents = carousel["contents"] as? [[String: Any]] else { return nil }

        var items: [ShelfItem] = []
        var hasListRows = false
        for entry in contents {
            if let twoRow = entry["musicTwoRowItemRenderer"] as? [String: Any],
               let parsed = parseTwoRowItem(twoRow) {
                items.append(parsed)
            } else if let responsive = entry["musicResponsiveListItemRenderer"] as? [String: Any] {
                hasListRows = true
                if let item = parseResponsiveShelfItem(responsive) {
                    items.append(item)
                }
            }
        }

        guard !items.isEmpty else { return nil }
        let finalTitle = title.isEmpty ? "For You" : title
        let style = inferShelfStyle(title: finalTitle, items: items, isListRowShelf: hasListRows)
        return ShelfSection(
            id: "carousel:\(finalTitle):\(items.first?.id ?? UUID().uuidString)",
            title: finalTitle,
            subtitle: strapline.isEmpty ? nil : strapline,
            style: style,
            items: items,
            browseId: moreBrowseId
        )
    }

    private static func parsePlainShelf(_ shelf: [String: Any]) -> ShelfSection? {
        let title = runsText(shelf["title"])
        guard let contents = shelf["contents"] as? [[String: Any]] else { return nil }

        var items: [ShelfItem] = []
        for entry in contents {
            if let responsive = entry["musicResponsiveListItemRenderer"] as? [String: Any],
               let item = parseResponsiveShelfItem(responsive) {
                items.append(item)
            } else if let twoRow = entry["musicTwoRowItemRenderer"] as? [String: Any],
                      let item = parseTwoRowItem(twoRow) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { return nil }
        let finalTitle = title.isEmpty ? "Highlights" : title
        return ShelfSection(
            id: "shelf:\(finalTitle):\(items.first?.id ?? UUID().uuidString)",
            title: finalTitle,
            style: .trackList,
            items: items
        )
    }

    private static func inferShelfStyle(title: String, items: [ShelfItem], isListRowShelf: Bool) -> ShelfStyle {
        let lower = title.lowercased()
        let artistCount = items.filter {
            if case .artist = $0 { return true }
            return false
        }.count
        if artistCount > 0 && artistCount * 2 >= items.count {
            return .artists
        }
        if isListRowShelf || lower.contains("quick picks") || lower.contains("top songs") || lower.contains("trending") {
            return .trackList
        }
        if lower.contains("featured") || lower.contains("spotlight") {
            return .hero
        }
        return .squareGrid
    }

    // MARK: - Search & Suggestions

    static func parseSearchSuggestions(from root: [String: Any]) -> [SearchSuggestion] {
        var suggestions: [SearchSuggestion] = []
        var seenText = Set<String>()

        for renderer in collectRenderers(in: root, named: "searchSuggestionRenderer") {
            let navQuery = ((renderer["navigationEndpoint"] as? [String: Any])?["searchEndpoint"] as? [String: Any])?["query"] as? String
            let text = (navQuery?.isEmpty == false ? navQuery : nil) ?? runsText(renderer["suggestion"])
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenText.insert(trimmed.lowercased()).inserted else { continue }
            suggestions.append(SearchSuggestion(id: "q:\(trimmed)", text: trimmed, item: nil))
        }

        for renderer in collectRenderers(in: root, named: "musicResponsiveListItemRenderer") {
            if let item = parseResponsiveShelfItem(renderer) {
                let text = item.title
                if !text.isEmpty {
                    suggestions.append(SearchSuggestion(id: "item:\(item.id)", text: text, item: item))
                }
            }
        }

        return suggestions
    }

    static func parseSearchResults(query: String, from root: [String: Any]) -> SearchResults {
        var topResult: ShelfItem?
        var songs: [Track] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []

        var seenTracks = Set<String>()
        var seenAlbums = Set<String>()
        var seenArtists = Set<String>()
        var seenPlaylists = Set<String>()

        // 1. Parse promoted top card (`musicCardShelfRenderer`) and collect artist credits for child rows.
        let cards = collectRenderers(in: root, named: "musicCardShelfRenderer")
        var cardArtistCreditByVideoId: [String: PageCredits] = [:]

        for card in cards {
            if topResult == nil {
                if let song = parseCardShelfSong(card) {
                    topResult = .track(song)
                    if seenTracks.insert(song.videoId).inserted {
                        songs.append(song)
                    }
                } else if let browse = parseCardShelfBrowse(card) {
                    topResult = browse
                    switch browse {
                    case .album(let a):
                        if seenAlbums.insert(a.id).inserted { albums.append(a) }
                    case .artist(let a):
                        if seenArtists.insert(a.id).inserted { artists.append(a) }
                    case .playlist(let p):
                        if seenPlaylists.insert(p.id).inserted { playlists.append(p) }
                    case .track(let t):
                        if seenTracks.insert(t.videoId).inserted { songs.append(t) }
                    }
                }
            }

            if let cardCredit = cardShelfArtistCredit(card) {
                for row in collectRenderers(in: card, named: "musicResponsiveListItemRenderer") {
                    if let vid = extractVideoId(from: row) {
                        cardArtistCreditByVideoId[vid] = cardCredit
                    }
                }
            }
        }

        // 2. Walk all responsive rows across search shelves.
        for row in collectRenderers(in: root, named: "musicResponsiveListItemRenderer") {
            if let browse = parseResponsiveBrowseItem(row) {
                switch browse {
                case .album(let a):
                    if seenAlbums.insert(a.id).inserted { albums.append(a) }
                case .artist(let a):
                    if seenArtists.insert(a.id).inserted { artists.append(a) }
                case .playlist(let p):
                    if seenPlaylists.insert(p.id).inserted { playlists.append(p) }
                case .track(let t):
                    if seenTracks.insert(t.videoId).inserted { songs.append(t) }
                }
            } else {
                let vid = extractVideoId(from: row)
                let fallback = vid.flatMap { cardArtistCreditByVideoId[$0] } ?? PageCredits()
                if let track = parseResponsiveTrack(row, fallback: fallback),
                   seenTracks.insert(track.videoId).inserted {
                    songs.append(track)
                }
            }
        }

        if topResult == nil {
            if let firstSong = songs.first {
                topResult = .track(firstSong)
            } else if let firstArtist = artists.first {
                topResult = .artist(firstArtist)
            } else if let firstAlbum = albums.first {
                topResult = .album(firstAlbum)
            } else if let firstPlaylist = playlists.first {
                topResult = .playlist(firstPlaylist)
            }
        }

        return SearchResults(
            query: query,
            topResult: topResult,
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists
        )
    }

    // MARK: - Album, Artist, Playlist Detail

    static func parseAlbum(browseId: String, from root: [String: Any]) -> Album {
        let header = findPrimaryHeader(in: root)
        let title = runsText(header?["title"])
        let pageCredits = extractPageCredits(from: header)
        let headerArt = bestThumbnailURL(in: header, targetSize: 1080)
        let description = parseDescription(from: root, header: header)
        let year = extractYear(from: header)
        let playlistId = extractAlbumPlaylistId(from: root, header: header)
        let isExplicit = hasExplicitBadge(header)

        let fallback = PageCredits(
            artistId: pageCredits.artistId,
            artistName: pageCredits.artistName,
            albumId: browseId,
            albumName: title.isEmpty ? nil : title,
            artworkURL: bestThumbnailURL(in: header, targetSize: 544)
        )

        var tracks: [Track] = []
        var seen = Set<String>()
        // Prefer secondaryContents / musicShelfRenderer so we don't accidentally mix "More from artist" shelves.
        let secondaryScope = ((root["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["secondaryContents"]
            ?? root
        let trackShelves = collectRenderers(in: secondaryScope, named: "musicShelfRenderer")
        let rowNodes: [[String: Any]]
        if let mainShelf = trackShelves.first {
            rowNodes = collectRenderers(in: mainShelf, named: "musicResponsiveListItemRenderer")
        } else {
            rowNodes = collectRenderers(in: secondaryScope, named: "musicResponsiveListItemRenderer")
        }

        for row in rowNodes {
            if var track = parseResponsiveTrack(row, fallback: fallback),
               seen.insert(track.videoId).inserted {
                if track.artworkURL == nil { track.artworkURL = fallback.artworkURL ?? headerArt }
                if track.album == nil && !title.isEmpty { track.album = title }
                if track.albumId == nil { track.albumId = browseId }
                tracks.append(track)
            }
        }

        return Album(
            id: browseId,
            title: title.isEmpty ? "Album" : title,
            artist: pageCredits.artistName ?? tracks.first?.artist ?? "Unknown Artist",
            artistId: pageCredits.artistId ?? tracks.first?.artistId,
            year: year,
            artworkURL: headerArt ?? tracks.first?.artworkURL,
            description: description,
            tracks: tracks,
            isExplicit: isExplicit,
            playlistId: playlistId
        )
    }

    static func parseArtist(browseId: String, from root: [String: Any]) -> Artist {
        let headerObj = root["header"] as? [String: Any]
        let immersive = headerObj?["musicImmersiveHeaderRenderer"] as? [String: Any]
        let visual = headerObj?["musicVisualHeaderRenderer"] as? [String: Any]
        let activeHeader = immersive ?? visual ?? findPrimaryHeader(in: root)

        let name = runsText(activeHeader?["title"])
        let description = parseDescription(from: root, header: activeHeader)
        let subscriberCount = parseArtistSubscriberCount(immersive: immersive)
            ?? firstRunText(immersive?["monthlyListenerCount"])

        let bannerURL: URL?
        let artworkURL: URL?
        if let visual {
            artworkURL = bestThumbnailURL(in: visual["foregroundThumbnail"], targetSize: 1080)
                ?? bestThumbnailURL(in: visual["thumbnail"], targetSize: 1080)
            bannerURL = bestThumbnailURL(in: visual["thumbnail"], targetSize: 1080, preserveWideBanner: true)
        } else {
            let thumb = bestThumbnailURL(in: activeHeader?["thumbnail"], targetSize: 1080)
                ?? bestThumbnailURL(in: activeHeader, targetSize: 1080)
            artworkURL = thumb
            bannerURL = bestThumbnailURL(in: activeHeader?["thumbnail"], targetSize: 1080, preserveWideBanner: true)
        }

        let shufflePlaylistId = extractHeaderButtonPlaylistId(immersive: immersive, buttonKey: "playButton")
        let radioPlaylistId = extractHeaderButtonPlaylistId(immersive: immersive, buttonKey: "startRadioButton")

        let artistCredit = PageCredits(artistId: browseId, artistName: name.isEmpty ? nil : name)

        let tabs = (root["contents"] as? [String: Any])?["singleColumnBrowseResultsRenderer"]
            .flatMap { ($0 as? [String: Any])?["tabs"] as? [[String: Any]] } ?? []
        let sections = tabs.first?["tabRenderer"]
            .flatMap { ($0 as? [String: Any])?["content"] as? [String: Any] }?["sectionListRenderer"]
            .flatMap { ($0 as? [String: Any])?["contents"] as? [[String: Any]] } ?? []

        var topSongs: [Track] = []
        var albums: [Album] = []
        var singles: [Album] = []
        var relatedArtists: [Artist] = []
        var seenSongs = Set<String>()

        for section in sections {
            if let shelf = section["musicShelfRenderer"] as? [String: Any] {
                for row in collectRenderers(in: shelf, named: "musicResponsiveListItemRenderer") {
                    if let track = parseResponsiveTrack(row, fallback: artistCredit),
                       seenSongs.insert(track.videoId).inserted {
                        topSongs.append(track)
                    }
                }
            } else if let carousel = section["musicCarouselShelfRenderer"] as? [String: Any] {
                let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
                let shelfTitle = runsText(header?["title"]).lowercased()
                let contents = carousel["contents"] as? [[String: Any]] ?? []

                for entry in contents {
                    guard let twoRow = entry["musicTwoRowItemRenderer"] as? [String: Any],
                          let item = parseTwoRowItem(twoRow, defaultArtist: name.isEmpty ? nil : name, defaultArtistId: browseId) else {
                        continue
                    }
                    switch item {
                    case .album(let album):
                        if shelfTitle.contains("single") || shelfTitle.contains("ep") {
                            singles.append(album)
                        } else {
                            albums.append(album)
                        }
                    case .artist(let related):
                        relatedArtists.append(related)
                    case .track(let track):
                        if seenSongs.insert(track.videoId).inserted {
                            topSongs.append(track)
                        }
                    case .playlist:
                        break
                    }
                }
            }
        }

        return Artist(
            id: browseId,
            name: name.isEmpty ? "Artist" : name,
            description: description,
            subscriberCount: subscriberCount,
            artworkURL: artworkURL,
            bannerURL: bannerURL,
            topSongs: topSongs,
            albums: albums,
            singles: singles,
            relatedArtists: relatedArtists,
            shufflePlaylistId: shufflePlaylistId,
            radioPlaylistId: radioPlaylistId
        )
    }

    static func parsePlaylist(browseId: String, from root: [String: Any]) -> Playlist {
        let header = findPrimaryHeader(in: root)
        let title = runsText(header?["title"])
        let author = extractPlaylistAuthor(from: header)
        let description = parseDescription(from: root, header: header)
        let artworkURL = bestThumbnailURL(in: header, targetSize: 1080)

        let secondaryScope = ((root["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["secondaryContents"]
            ?? root

        let playlistShelf = collectRenderers(in: secondaryScope, named: "musicPlaylistShelfRenderer").first
            ?? collectRenderers(in: secondaryScope, named: "musicShelfRenderer").first

        let rowNodes = playlistShelf.map { collectRenderers(in: $0, named: "musicResponsiveListItemRenderer") }
            ?? collectRenderers(in: secondaryScope, named: "musicResponsiveListItemRenderer")

        var tracks: [Track] = []
        var seen = Set<String>()
        for row in rowNodes {
            if let track = parseResponsiveTrack(row), seen.insert(track.videoId).inserted {
                tracks.append(track)
            }
        }

        return Playlist(
            id: browseId,
            title: title.isEmpty ? "Playlist" : title,
            author: author,
            description: description,
            artworkURL: artworkURL ?? tracks.first?.artworkURL,
            tracks: tracks,
            isUserCreated: false
        )
    }

    static func parsePlaylistContinuationTracks(from root: [String: Any]) -> [Track] {
        let scope = root["continuationContents"] ?? root
        let shelf = (scope as? [String: Any])?["musicPlaylistShelfContinuation"]
            ?? collectRenderers(in: scope, named: "musicPlaylistShelfRenderer").first
            ?? scope
        var tracks: [Track] = []
        var seen = Set<String>()
        for row in collectRenderers(in: shelf, named: "musicResponsiveListItemRenderer") {
            if let track = parseResponsiveTrack(row), seen.insert(track.videoId).inserted {
                tracks.append(track)
            }
        }
        return tracks
    }

    static func playlistContinuationToken(from root: [String: Any]) -> String? {
        let scope = root["continuationContents"]
            ?? ((root["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["secondaryContents"]
            ?? root
        if let playlistScope = (scope as? [String: Any])?["musicPlaylistShelfContinuation"]
            ?? collectRenderers(in: scope, named: "musicPlaylistShelfRenderer").first {
            return continuationToken(from: playlistScope)
        }
        return nil
    }

    // MARK: - Watch Queue / Up Next Radio

    static func parseWatchQueue(from root: [String: Any]) -> [Track] {
        var replacements: [String: [String: Any]] = [:]
        var dropped = Set<String>()

        for wrapper in collectRenderers(in: root, named: "playlistPanelVideoWrapperRenderer") {
            let primary = (wrapper["primaryRenderer"] as? [String: Any])?["playlistPanelVideoRenderer"] as? [String: Any]
            let counterparts = (wrapper["counterpart"] as? [[String: Any]] ?? [])
                .compactMap { ($0["counterpartRenderer"] as? [String: Any])?["playlistPanelVideoRenderer"] as? [String: Any] }
            let halves = [primary].compactMap { $0 } + counterparts
            guard let first = halves.first, let firstId = first["videoId"] as? String else { continue }

            if let atv = halves.first(where: { isAudioTrackVariant($0) }) {
                replacements[firstId] = atv
                for other in halves {
                    if let oid = other["videoId"] as? String, oid != firstId {
                        dropped.insert(oid)
                    }
                }
            }
        }

        var tracks: [Track] = []
        var seen = Set<String>()
        for panel in collectRenderers(in: root, named: "playlistPanelVideoRenderer") {
            guard let vid = panel["videoId"] as? String, !dropped.contains(vid) else { continue }
            let chosen = replacements[vid] ?? panel
            if let track = parsePlaylistPanelTrack(chosen), seen.insert(track.videoId).inserted {
                tracks.append(track)
            }
        }
        return tracks
    }

    private static func isAudioTrackVariant(_ renderer: [String: Any]) -> Bool {
        let nav = renderer["navigationEndpoint"] as? [String: Any]
        let watch = nav?["watchEndpoint"] as? [String: Any]
        let configs = watch?["watchEndpointMusicSupportedConfigs"] as? [String: Any]
        let musicCfg = configs?["watchEndpointMusicConfig"] as? [String: Any]
        return (musicCfg?["musicVideoType"] as? String) == "MUSIC_VIDEO_TYPE_ATV"
    }

    private static func parsePlaylistPanelTrack(_ renderer: [String: Any]) -> Track? {
        guard let videoId = renderer["videoId"] as? String, !videoId.isEmpty else { return nil }
        let title = runsText(renderer["title"])
        guard !title.isEmpty else { return nil }

        let bylineRuns = ((renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? []
        let credits = creditsFromRuns(bylineRuns)
        let artistSegment = bylineRuns
            .prefix(while: { (($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces) != "•" })
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let artistName = artistNamesFromRuns(bylineRuns)
            ?? credits.artistName
            ?? (artistSegment.isEmpty ? nil : artistSegment)
            ?? "Unknown Artist"

        let durationText = runsText(renderer["lengthText"])
        let duration = parseDurationString(durationText) ?? 0
        let artworkURL = bestThumbnailURL(in: renderer["thumbnail"], targetSize: 544)

        return Track(
            videoId: videoId,
            title: title,
            artist: artistName,
            artistId: credits.artistId,
            album: credits.albumName,
            albumId: credits.albumId,
            duration: duration,
            artworkURL: artworkURL,
            isExplicit: hasExplicitBadge(renderer)
        )
    }

    // MARK: - Item Renderers

    private static func parseTwoRowItem(
        _ renderer: [String: Any],
        defaultArtist: String? = nil,
        defaultArtistId: String? = nil
    ) -> ShelfItem? {
        let title = runsText(renderer["title"])
        guard !title.isEmpty else { return nil }

        let nav = renderer["navigationEndpoint"] as? [String: Any]
        let browseEndpoint = nav?["browseEndpoint"] as? [String: Any]
        let watchEndpoint = nav?["watchEndpoint"] as? [String: Any]
        let rawBrowseId = browseEndpoint?["browseId"] as? String
        let pageType = extractPageType(from: browseEndpoint)

        let subtitleRuns = (renderer["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let subtitle = runsText(renderer["subtitle"])
        let credits = creditsFromRuns(subtitleRuns)
        let artworkURL = bestThumbnailURL(in: renderer["thumbnailRenderer"], targetSize: 544)
        let isExplicit = hasExplicitBadge(renderer)

        // Direct playable song or MPED non-music audio track
        if let videoId = watchEndpoint?["videoId"] as? String, !videoId.isEmpty {
            let artist = artistNamesFromRuns(subtitleRuns)
                ?? credits.artistName
                ?? artistFromSubtitle(subtitle)
                ?? defaultArtist
                ?? "Unknown Artist"
            return .track(Track(
                videoId: videoId,
                title: title,
                artist: artist,
                artistId: credits.artistId ?? defaultArtistId,
                album: credits.albumName,
                albumId: credits.albumId,
                artworkURL: artworkURL,
                isExplicit: isExplicit
            ))
        }

        if let rawBrowseId, rawBrowseId.hasPrefix("MPED") {
            let videoId = String(rawBrowseId.dropFirst(4))
            if !videoId.isEmpty {
                let artist = artistFromSubtitle(subtitle) ?? defaultArtist ?? "Unknown Artist"
                return .track(Track(
                    videoId: videoId,
                    title: title,
                    artist: artist,
                    artistId: credits.artistId ?? defaultArtistId,
                    artworkURL: artworkURL,
                    isExplicit: isExplicit
                ))
            }
        }

        guard let browseId = rawBrowseId, !browseId.isEmpty else { return nil }

        if pageType.contains("ARTIST") || browseId.hasPrefix("UC") {
            return .artist(Artist(
                id: browseId,
                name: title,
                subscriberCount: subtitle.isEmpty ? nil : subtitle,
                artworkURL: artworkURL
            ))
        }

        if pageType.contains("ALBUM") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let year = extractYearFromText(subtitle)
            let artist = artistNamesFromRuns(subtitleRuns)
                ?? credits.artistName
                ?? artistFromSubtitle(subtitle)
                ?? defaultArtist
                ?? "Unknown Artist"
            return .album(Album(
                id: browseId,
                title: title,
                artist: artist,
                artistId: credits.artistId ?? defaultArtistId,
                year: year,
                artworkURL: artworkURL,
                isExplicit: isExplicit
            ))
        }

        // Default to playlist for VL / PL / RD / browse playlists
        let author = artistFromSubtitle(subtitle) ?? (subtitle.isEmpty ? nil : subtitle)
        return .playlist(Playlist(
            id: browseId,
            title: title,
            author: author,
            artworkURL: artworkURL
        ))
    }

    private static func parseResponsiveShelfItem(_ renderer: [String: Any]) -> ShelfItem? {
        if let browse = parseResponsiveBrowseItem(renderer) {
            return browse
        }
        if let track = parseResponsiveTrack(renderer) {
            return .track(track)
        }
        return nil
    }

    private static func parseResponsiveBrowseItem(_ renderer: [String: Any]) -> ShelfItem? {
        guard let browseEndpoint = (renderer["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              !browseId.isEmpty else {
            return nil
        }

        let pageType = extractPageType(from: browseEndpoint)
        let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
        let title = flexColumnText(columns, index: 0)
        guard !title.isEmpty else { return nil }

        let subtitleRuns = flexColumnRuns(columns, index: 1)
        let subtitle = flexColumnText(columns, index: 1)
        let credits = creditsFromRuns(subtitleRuns)
        let artworkURL = bestThumbnailURL(in: renderer["thumbnail"], targetSize: 544)
        let isExplicit = hasExplicitBadge(renderer)

        if pageType.contains("ARTIST") || browseId.hasPrefix("UC") {
            return .artist(Artist(
                id: browseId,
                name: title,
                subscriberCount: subtitle.isEmpty ? nil : subtitle,
                artworkURL: artworkURL
            ))
        }

        if pageType.contains("ALBUM") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let year = extractYearFromText(subtitle)
            let artist = artistNamesFromRuns(subtitleRuns)
                ?? credits.artistName
                ?? artistFromSubtitle(subtitle)
                ?? "Unknown Artist"
            return .album(Album(
                id: browseId,
                title: title,
                artist: artist,
                artistId: credits.artistId,
                year: year,
                artworkURL: artworkURL,
                isExplicit: isExplicit
            ))
        }

        if pageType.contains("PLAYLIST") || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            return .playlist(Playlist(
                id: browseId,
                title: title,
                author: artistFromSubtitle(subtitle) ?? (subtitle.isEmpty ? nil : subtitle),
                artworkURL: artworkURL
            ))
        }

        return nil
    }

    private static func parseResponsiveTrack(
        _ renderer: [String: Any],
        fallback: PageCredits = PageCredits()
    ) -> Track? {
        guard let videoId = extractVideoId(from: renderer), !videoId.isEmpty else { return nil }

        let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
        let title = flexColumnText(columns, index: 0)
        guard !title.isEmpty else { return nil }

        let subtitleRuns = flexColumnRuns(columns, index: 1)
        let subtitle = flexColumnText(columns, index: 1)
        let parts = subtitle.components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Duration from subtitle or fixedColumns (album pages put duration in fixedColumns)
        var durationStr: String? = parts.last.flatMap { isDurationToken($0) ? $0 : nil }
        if durationStr == nil, let fixedColumns = renderer["fixedColumns"] as? [[String: Any]] {
            for col in fixedColumns {
                let text = runsText((col["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"])
                if isDurationToken(text) {
                    durationStr = text
                    break
                }
            }
        }
        if durationStr == nil, columns.count > 2 {
            let thirdText = flexColumnText(columns, index: 2)
            if isDurationToken(thirdText) {
                durationStr = thirdText
            }
        }

        let allFlexRuns = columns.flatMap { col -> [[String: Any]] in
            ((col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        }
        let credits = creditsFromRuns(allFlexRuns)
        let creditedArtists = artistNamesFromRuns(subtitleRuns)
        let guessedArtist = parts.first { part in
            let lower = part.lowercased()
            return !isDurationToken(part) && !typeWords.contains(lower) && !isTallyToken(part) && !isYearToken(part)
        }

        let artist = creditedArtists
            ?? credits.artistName
            ?? guessedArtist
            ?? fallback.artistName
            ?? "Unknown Artist"

        let artworkURL = bestThumbnailURL(in: renderer["thumbnail"], targetSize: 544) ?? fallback.artworkURL

        return Track(
            videoId: videoId,
            title: title,
            artist: artist,
            artistId: credits.artistId ?? fallback.artistId,
            album: credits.albumName ?? fallback.albumName,
            albumId: credits.albumId ?? fallback.albumId,
            duration: durationStr.flatMap(parseDurationString) ?? 0,
            artworkURL: artworkURL,
            isExplicit: hasExplicitBadge(renderer)
        )
    }

    private static func parseCardShelfSong(_ card: [String: Any]) -> Track? {
        guard let videoId = ((card["onTap"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String,
              !videoId.isEmpty else {
            return nil
        }
        let title = runsText(card["title"])
        guard !title.isEmpty else { return nil }

        let subtitleRuns = (card["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let subtitle = runsText(card["subtitle"])
        let parts = subtitle.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let duration = parts.last.flatMap { isDurationToken($0) ? parseDurationString($0) : nil } ?? 0
        let credits = creditsFromRuns(subtitleRuns)
        let artist = artistNamesFromRuns(subtitleRuns)
            ?? credits.artistName
            ?? artistFromSubtitle(subtitle)
            ?? "Unknown Artist"

        return Track(
            videoId: videoId,
            title: title,
            artist: artist,
            artistId: credits.artistId,
            album: credits.albumName,
            albumId: credits.albumId,
            duration: duration,
            artworkURL: bestThumbnailURL(in: card["thumbnail"], targetSize: 544),
            isExplicit: hasExplicitBadge(card["subtitleBadges"])
        )
    }

    private static func parseCardShelfBrowse(_ card: [String: Any]) -> ShelfItem? {
        guard let browseEndpoint = (card["onTap"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              !browseId.isEmpty else {
            return nil
        }
        let pageType = extractPageType(from: browseEndpoint)
        if pageType.contains("NON_MUSIC_AUDIO_TRACK") { return nil }

        let title = runsText(card["title"])
        guard !title.isEmpty else { return nil }
        let subtitleRuns = (card["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let subtitle = runsText(card["subtitle"])
        let credits = creditsFromRuns(subtitleRuns)
        let artworkURL = bestThumbnailURL(in: card["thumbnail"], targetSize: 544)

        if pageType.contains("ARTIST") || browseId.hasPrefix("UC") {
            return .artist(Artist(
                id: browseId,
                name: title,
                subscriberCount: subtitle.isEmpty ? nil : subtitle,
                artworkURL: artworkURL
            ))
        }
        if pageType.contains("ALBUM") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return .album(Album(
                id: browseId,
                title: title,
                artist: artistNamesFromRuns(subtitleRuns) ?? credits.artistName ?? artistFromSubtitle(subtitle) ?? "Unknown Artist",
                artistId: credits.artistId,
                year: extractYearFromText(subtitle),
                artworkURL: artworkURL,
                isExplicit: hasExplicitBadge(card["subtitleBadges"])
            ))
        }
        return .playlist(Playlist(
            id: browseId,
            title: title,
            author: artistFromSubtitle(subtitle) ?? (subtitle.isEmpty ? nil : subtitle),
            artworkURL: artworkURL
        ))
    }

    private static func cardShelfArtistCredit(_ card: [String: Any]) -> PageCredits? {
        guard let browseEndpoint = (card["onTap"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String else {
            return nil
        }
        let pageType = extractPageType(from: browseEndpoint)
        guard pageType.contains("ARTIST") || browseId.hasPrefix("UC") else { return nil }
        let name = runsText(card["title"])
        guard !name.isEmpty else { return nil }
        return PageCredits(artistId: browseId, artistName: name)
    }

    // MARK: - Header & Credit Extraction Helpers

    private struct PageCredits {
        var artistId: String?
        var artistName: String?
        var albumId: String?
        var albumName: String?
        var artworkURL: URL?
    }

    private static func findPrimaryHeader(in root: [String: Any]) -> [String: Any]? {
        if let editable = collectRenderers(in: root, named: "musicEditablePlaylistDetailHeaderRenderer").first,
           let innerHeader = (editable["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any]
            ?? (editable["header"] as? [String: Any])?["musicDetailHeaderRenderer"] as? [String: Any] {
            return innerHeader
        }
        for key in headerRendererKeys {
            if let found = collectRenderers(in: root, named: key).first {
                return found
            }
        }
        return nil
    }

    private static func extractPageCredits(from header: [String: Any]?) -> PageCredits {
        guard let header else { return PageCredits() }
        let straplineRuns = (header["straplineTextOne"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let subtitleRuns = (header["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        let allRuns = straplineRuns + subtitleRuns
        let credits = creditsFromRuns(allRuns)
        let linkedArtists = artistNamesFromRuns(straplineRuns) ?? artistNamesFromRuns(subtitleRuns)
        if let linkedArtists {
            return PageCredits(artistId: credits.artistId, artistName: linkedArtists, albumId: credits.albumId, albumName: credits.albumName)
        }
        let straplineText = runsText(header["straplineTextOne"])
        if !straplineText.isEmpty && !typeWords.contains(straplineText.lowercased()) {
            return PageCredits(artistId: credits.artistId, artistName: straplineText, albumId: credits.albumId, albumName: credits.albumName)
        }
        let subtitleText = runsText(header["subtitle"])
        let guessed = artistFromSubtitle(subtitleText)
        return PageCredits(artistId: credits.artistId, artistName: credits.artistName ?? guessed, albumId: credits.albumId, albumName: credits.albumName)
    }

    private static func extractPlaylistAuthor(from header: [String: Any]?) -> String? {
        guard let header else { return nil }
        let strapline = runsText(header["straplineTextOne"])
        if !strapline.isEmpty { return strapline }
        let subtitle = runsText(header["subtitle"])
        return artistFromSubtitle(subtitle) ?? (subtitle.isEmpty ? nil : subtitle)
    }

    private static func extractYear(from header: [String: Any]?) -> String? {
        guard let header else { return nil }
        let combined = [runsText(header["subtitle"]), runsText(header["secondSubtitle"])].joined(separator: " • ")
        return extractYearFromText(combined)
    }

    private static func extractYearFromText(_ text: String) -> String? {
        if let range = text.range(of: #"\b(19\d{2}|20\d{2})\b"#, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    private static func extractAlbumPlaylistId(from root: [String: Any], header: [String: Any]?) -> String? {
        if let header {
            for key in ["musicPlayButtonRenderer", "buttonRenderer"] {
                for btn in collectRenderers(in: header, named: key) {
                    let ep = (btn["playNavigationEndpoint"] as? [String: Any])
                        ?? (btn["navigationEndpoint"] as? [String: Any])
                        ?? btn
                    if let pid = (ep["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String
                        ?? (ep["watchEndpoint"] as? [String: Any])?["playlistId"] as? String,
                       !pid.isEmpty {
                        return pid
                    }
                }
            }
        }
        if let canonical = ((root["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any])?["urlCanonical"] as? String,
           let range = canonical.range(of: "list=") {
            let after = canonical[range.upperBound...]
            let pid = String(after.prefix { $0 != "&" })
            if !pid.isEmpty { return pid }
        }
        return nil
    }

    private static func parseDescription(from root: [String: Any], header: [String: Any]?) -> String? {
        if let shelf = collectRenderers(in: root, named: "musicDescriptionShelfRenderer").first {
            let text = runsText(shelf["description"])
            if !text.isEmpty { return text }
        }
        if let header {
            let text = runsText(header["description"])
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func parseArtistSubscriberCount(immersive: [String: Any]?) -> String? {
        guard let immersive else { return nil }
        let btn2 = (immersive["subscriptionButton2"] as? [String: Any])?["subscribeButtonRenderer"] as? [String: Any]
        let btn1 = (immersive["subscriptionButton"] as? [String: Any])?["subscribeButtonRenderer"] as? [String: Any]
        return firstRunText(btn2?["subscriberCountWithSubscribeText"])
            ?? firstRunText(btn1?["longSubscriberCountText"])
            ?? firstRunText(btn1?["shortSubscriberCountText"])
    }

    private static func extractHeaderButtonPlaylistId(immersive: [String: Any]?, buttonKey: String) -> String? {
        guard let btn = (immersive?[buttonKey] as? [String: Any])?["buttonRenderer"] as? [String: Any],
              let nav = btn["navigationEndpoint"] as? [String: Any] else {
            return nil
        }
        return (nav["watchEndpoint"] as? [String: Any])?["playlistId"] as? String
            ?? (nav["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String
    }

    private static func extractMoreBrowseId(from header: [String: Any]?) -> String? {
        guard let header else { return nil }
        if let runs = (header["title"] as? [String: Any])?["runs"] as? [[String: Any]] {
            for run in runs {
                if let bid = ((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
                    return bid
                }
            }
        }
        let more = header["moreContentButton"] as? [String: Any]
        let btn = (more?["buttonRenderer"] as? [String: Any]) ?? (more?["musicMoreContentButtonRenderer"] as? [String: Any])
        if let bid = ((btn?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
            return bid
        }
        return ((header["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    private static func extractVideoId(from renderer: [String: Any]) -> String? {
        if let vid = (renderer["playlistItemData"] as? [String: Any])?["videoId"] as? String, !vid.isEmpty {
            return vid
        }
        let overlay = (renderer["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any]
        let playBtn = (overlay?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any]
        if let vid = ((playBtn?["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String, !vid.isEmpty {
            return vid
        }
        if let columns = renderer["flexColumns"] as? [[String: Any]] {
            for run in flexColumnRuns(columns, index: 0) {
                if let vid = ((run["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String, !vid.isEmpty {
                    return vid
                }
            }
        }
        return nil
    }

    private static func creditsFromRuns(_ runs: [[String: Any]]) -> PageCredits {
        var result = PageCredits()
        for run in runs {
            guard let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                  let id = browse["browseId"] as? String, !id.isEmpty else {
                continue
            }
            let pageType = extractPageType(from: browse)
            let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageType.contains("ARTIST") || id.hasPrefix("UC") {
                if result.artistId == nil {
                    result.artistId = id
                    if !text.isEmpty { result.artistName = text }
                }
            } else if pageType.contains("ALBUM") || id.hasPrefix("MPRE") {
                if result.albumId == nil {
                    result.albumId = id
                    if !text.isEmpty { result.albumName = text }
                }
            }
        }
        return result
    }

    private static func artistNamesFromRuns(_ runs: [[String: Any]]) -> String? {
        var groups: [[[String: Any]]] = [[]]
        for run in runs {
            if ((run["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "•" {
                groups.append([])
            } else {
                groups[groups.count - 1].append(run)
            }
        }
        guard let artistGroup = groups.first(where: { group in
            group.contains { run in
                let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
                let pageType = extractPageType(from: browse)
                let bid = browse?["browseId"] as? String ?? ""
                return pageType.contains("ARTIST") || bid.hasPrefix("UC")
            }
        }) else {
            return nil
        }

        var names: [String] = []
        for (idx, run) in artistGroup.enumerated() where idx % 2 == 0 {
            if let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, !names.contains(text) {
                names.append(text)
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func artistFromSubtitle(_ subtitle: String) -> String? {
        let parts = subtitle
            .components(separatedBy: CharacterSet(charactersIn: "•·"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.first { part in
            let lower = part.lowercased()
            return !typeWords.contains(lower) && !isDurationToken(part) && !isTallyToken(part) && !isYearToken(part)
        }
    }

    // MARK: - Continuation Token

    static func continuationToken(from root: Any) -> String? {
        if let item = collectRenderers(in: root, named: "continuationItemRenderer").first,
           let endpoint = item["continuationEndpoint"] as? [String: Any] {
            if let token = (endpoint["continuationCommand"] as? [String: Any])?["token"] as? String, !token.isEmpty {
                return token
            }
            if let commands = (endpoint["commandExecutorCommand"] as? [String: Any])?["commands"] as? [[String: Any]] {
                for cmd in commands {
                    if let token = (cmd["continuationCommand"] as? [String: Any])?["token"] as? String, !token.isEmpty {
                        return token
                    }
                }
            }
        }
        if let nextData = collectRenderers(in: root, named: "nextContinuationData").first,
           let token = nextData["continuation"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    // MARK: - Low-Level JSON & Artwork Helpers

    static func collectRenderers(in node: Any?, named key: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ current: Any?) {
            if let dict = current as? [String: Any] {
                if let matched = dict[key] as? [String: Any] {
                    result.append(matched)
                }
                for value in dict.values {
                    walk(value)
                }
            } else if let array = current as? [Any] {
                for element in array {
                    walk(element)
                }
            }
        }
        walk(node)
        return result
    }

    static func runsText(_ node: Any?) -> String {
        guard let dict = node as? [String: Any] else { return "" }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let simple = dict["simpleText"] as? String {
            return simple.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func firstRunText(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]],
              let first = runs.first?["text"] as? String else {
            return nil
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func flexColumnText(_ columns: [[String: Any]], index: Int) -> String {
        guard index < columns.count else { return "" }
        let renderer = columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        return runsText(renderer?["text"])
    }

    private static func flexColumnRuns(_ columns: [[String: Any]], index: Int) -> [[String: Any]] {
        guard index < columns.count else { return [] }
        let renderer = columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        return (renderer?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
    }

    private static func extractPageType(from browseEndpoint: [String: Any]?) -> String {
        let supported = browseEndpoint?["browseEndpointContextSupportedConfigs"] as? [String: Any]
        let musicConfig = supported?["browseEndpointContextMusicConfig"] as? [String: Any]
        return (musicConfig?["pageType"] as? String) ?? ""
    }

    private static func hasExplicitBadge(_ node: Any?) -> Bool {
        if let str = node as? String {
            return str == "MUSIC_EXPLICIT_BADGE"
        }
        if let dict = node as? [String: Any] {
            return dict.values.contains { hasExplicitBadge($0) }
        }
        if let array = node as? [Any] {
            return array.contains { hasExplicitBadge($0) }
        }
        return false
    }

    static func bestThumbnailURL(in node: Any?, targetSize: Int = 544, preserveWideBanner: Bool = false) -> URL? {
        guard let node else { return nil }
        var candidates: [[String: Any]] = []

        if let dict = node as? [String: Any] {
            if let direct = dict["thumbnails"] as? [[String: Any]] {
                candidates = direct
            } else if let musicThumb = dict["musicThumbnailRenderer"] as? [String: Any],
                      let nested = (musicThumb["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] {
                candidates = nested
            } else if let firstRenderer = collectRenderers(in: dict, named: "musicThumbnailRenderer").first,
                      let nested = (firstRenderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] {
                candidates = nested
            }
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let lw = (lhs["width"] as? NSNumber)?.intValue ?? 0
            let rw = (rhs["width"] as? NSNumber)?.intValue ?? 0
            return lw < rw
        }) ?? candidates.last,
              let rawURLString = best["url"] as? String else {
            return nil
        }

        let normalizedStr = rawURLString.hasPrefix("//") ? "https:\(rawURLString)" : rawURLString
        guard let url = URL(string: normalizedStr) else { return nil }

        let width = (best["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (best["height"] as? NSNumber)?.doubleValue ?? 0
        if preserveWideBanner && width > 0 && height > 0 && width / height > 1.4 {
            return upgradeArtworkURL(url, width: targetSize, height: Int(Double(targetSize) * (height / width)))
        }
        return upgradeArtworkURL(url, width: targetSize, height: targetSize)
    }

    static func upgradeArtworkURL(_ url: URL, width: Int, height: Int) -> URL {
        let raw = url.absoluteString
        guard raw.contains("lh3.googleusercontent.com") || raw.contains("yt3.ggpht.com") else {
            return url
        }
        if let range = raw.range(of: #"=w\d+-h\d+[^&\s]*"#, options: .regularExpression) {
            var upgraded = raw
            upgraded.replaceSubrange(range, with: "=w\(width)-h\(height)-l90-rj")
            if let result = URL(string: upgraded) {
                return result
            }
        }
        if let range = raw.range(of: #"=s\d+[^&\s]*"#, options: .regularExpression) {
            var upgraded = raw
            upgraded.replaceSubrange(range, with: "=w\(width)-h\(height)-l90-rj")
            if let result = URL(string: upgraded) {
                return result
            }
        }
        return url
    }

    private static func isDurationToken(_ text: String) -> Bool {
        text.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func isYearToken(_ text: String) -> Bool {
        text.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isTallyToken(_ text: String) -> Bool {
        text.range(
            of: #"^[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func parseDurationString(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDurationToken(trimmed) else { return nil }
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
