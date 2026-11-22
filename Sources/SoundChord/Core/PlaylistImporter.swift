import Foundation

// MARK: - Public Import Models & Errors

public enum ImportPlatform: String, CaseIterable, Identifiable, Sendable {
    case youtubeMusic
    case youtube
    case spotify
    case appleMusic
    case deezer
    case soundcloud
    case tidal
    case localFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtubeMusic: return "YouTube Music"
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .deezer: return "Deezer"
        case .soundcloud: return "SoundCloud"
        case .tidal: return "Tidal"
        case .localFile: return "M3U / CSV File"
        }
    }

    public var iconName: String {
        switch self {
        case .youtubeMusic: return "play.circle.fill"
        case .youtube: return "play.rectangle.fill"
        case .spotify: return "waveform.circle.fill"
        case .appleMusic: return "music.note"
        case .deezer: return "dot.radiowaves.left.and.right"
        case .soundcloud: return "cloud.fill"
        case .tidal: return "water.waves"
        case .localFile: return "doc.text.fill"
        }
    }
}

public enum CandidateMatchStatus: String, Sendable, Hashable {
    case pending
    case matched
    case notFound
}

public struct ImportedTrackCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public var sourceTitle: String
    public var sourceArtist: String
    public var sourceAlbum: String?
    public var sourceDuration: TimeInterval
    public var matchedTrack: Track?
    public var isSelected: Bool
    public var matchScore: Double
    public var status: CandidateMatchStatus

    public init(
        id: String = UUID().uuidString,
        sourceTitle: String,
        sourceArtist: String,
        sourceAlbum: String? = nil,
        sourceDuration: TimeInterval = 0,
        matchedTrack: Track? = nil,
        isSelected: Bool = false,
        matchScore: Double = 0.0,
        status: CandidateMatchStatus = .pending
    ) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.sourceArtist = sourceArtist
        self.sourceAlbum = sourceAlbum
        self.sourceDuration = sourceDuration
        self.matchedTrack = matchedTrack
        self.isSelected = isSelected
        self.matchScore = matchScore
        self.status = status
    }
}

public struct ImportedPlaylistPreview: Sendable, Hashable {
    public var platform: ImportPlatform
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var sourceURL: String
    public var candidates: [ImportedTrackCandidate]
    public var warningNote: String?

    public init(
        platform: ImportPlatform,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        sourceURL: String,
        candidates: [ImportedTrackCandidate],
        warningNote: String? = nil
    ) {
        self.platform = platform
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.sourceURL = sourceURL
        self.candidates = candidates
        self.warningNote = warningNote
    }
}

public enum PlaylistImportError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unsupportedPlatform
    case emptyPlaylist
    case networkError(String)
    case gatedPlatform(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid playlist or album URL."
        case .unsupportedPlatform:
            return "Unsupported playlist source. Try YouTube, Spotify, Apple Music, Deezer, SoundCloud, Tidal, or an M3U/CSV file."
        case .emptyPlaylist:
            return "No tracks were found in this playlist."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .gatedPlatform(let detail):
            return detail
        }
    }
}

// MARK: - Playlist Importer Actor

public actor PlaylistImporter {
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let tidalGatedMessage =
        "Tidal blocked public playlist listing. Export your playlist as M3U or CSV and use From File import."

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 35
            config.httpAdditionalHeaders = [
                "User-Agent": Self.browserUserAgent,
                "Accept-Language": "en-US,en;q=0.9"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Platform Detection

    public static func detectPlatform(from rawURL: String) -> ImportPlatform? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("spotify:playlist:") || lower.hasPrefix("spotify:album:") {
            return .spotify
        }

        if lower.hasPrefix("file://") {
            return .localFile
        }
        if (lower.hasPrefix("/") || lower.hasPrefix("~/")) &&
            (lower.hasSuffix(".m3u") || lower.hasSuffix(".m3u8") || lower.hasSuffix(".csv")) {
            return .localFile
        }

        guard let url = normalizedWebURL(from: trimmed),
              let host = url.host?.lowercased() else {
            return nil
        }

        let normalizedHost = stripCommonSubdomains(host)

        if host == "music.youtube.com" {
            return .youtubeMusic
        }
        if normalizedHost == "youtube.com" || normalizedHost == "youtu.be" || normalizedHost == "youtube-nocookie.com" {
            return .youtube
        }
        if normalizedHost == "spotify.com" || host == "open.spotify.com" || host == "play.spotify.com" || normalizedHost == "spotify.link" {
            return .spotify
        }
        if host == "music.apple.com" || host == "itunes.apple.com" || host == "embed.music.apple.com" {
            return .appleMusic
        }
        if normalizedHost == "deezer.com" || host == "api.deezer.com" || host == "dzr.page.link" || host == "deezer.page.link" {
            return .deezer
        }
        if normalizedHost == "soundcloud.com" || host == "on.soundcloud.com" {
            return .soundcloud
        }
        if normalizedHost == "tidal.com" || host == "listen.tidal.com" || host == "embed.tidal.com" {
            return .tidal
        }

        return nil
    }

    // MARK: - Remote Playlist Extraction

    public func extractPlaylist(
        from rawURL: String,
        innerTube: InnerTubeServiceProtocol
    ) async throws -> ImportedPlaylistPreview {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlaylistImportError.invalidURL
        }

        if let lower = Optional(trimmed.lowercased()),
           lower.hasPrefix("file://") ||
           ((lower.hasPrefix("/") || lower.hasPrefix("~/")) &&
            (lower.hasSuffix(".m3u") || lower.hasSuffix(".m3u8") || lower.hasSuffix(".csv"))) {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            let fileURL = lower.hasPrefix("file://") ? (URL(string: trimmed) ?? URL(fileURLWithPath: expanded)) : URL(fileURLWithPath: expanded)
            return try extractFromLocalFile(url: fileURL)
        }

        guard let platform = Self.detectPlatform(from: trimmed) else {
            if Self.normalizedWebURL(from: trimmed) != nil {
                throw PlaylistImportError.unsupportedPlatform
            }
            throw PlaylistImportError.invalidURL
        }

        switch platform {
        case .youtubeMusic, .youtube:
            return try await extractYouTubePlaylist(rawURL: trimmed, platform: platform, innerTube: innerTube)
        case .spotify:
            return try await extractSpotifyPlaylist(rawURL: trimmed)
        case .appleMusic:
            return try await extractAppleMusicPlaylist(rawURL: trimmed)
        case .deezer:
            return try await extractDeezerPlaylist(rawURL: trimmed)
        case .soundcloud:
            return try await extractSoundCloudPlaylist(rawURL: trimmed)
        case .tidal:
            return try await extractTidalPlaylist(rawURL: trimmed)
        case .localFile:
            guard let url = URL(string: trimmed) else {
                throw PlaylistImportError.invalidURL
            }
            return try extractFromLocalFile(url: url)
        }
    }

    // MARK: - Local File Extraction

    public func extractFromLocalFile(url: URL) throws -> ImportedPlaylistPreview {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        let defaultTitle = url.deletingPathExtension().lastPathComponent
        let cleanTitle = defaultTitle.isEmpty ? "Imported Playlist" : defaultTitle

        let content: String
        do {
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                content = utf8
            } else {
                content = try String(contentsOf: url, encoding: .isoLatin1)
            }
        } catch {
            throw PlaylistImportError.networkError("Could not read file: \(error.localizedDescription)")
        }

        switch ext {
        case "m3u", "m3u8":
            return try Self.parseM3UContent(content, sourceURL: url.absoluteString, defaultTitle: cleanTitle)
        case "csv":
            return try Self.parseCSVContent(content, sourceURL: url.absoluteString, defaultTitle: cleanTitle)
        default:
            throw PlaylistImportError.unsupportedPlatform
        }
    }

    // MARK: - Concurrent InnerTube Track Matching

    public func matchCandidates(
        _ preview: ImportedPlaylistPreview,
        innerTube: InnerTubeServiceProtocol,
        onProgress: @Sendable (Int, Int) -> Void
    ) async -> ImportedPlaylistPreview {
        var updated = preview
        let total = updated.candidates.count
        guard total > 0 else {
            onProgress(0, 0)
            return updated
        }

        let pendingIndices = updated.candidates.indices.filter {
            updated.candidates[$0].status != .matched || updated.candidates[$0].matchedTrack == nil
        }

        let alreadyMatched = total - pendingIndices.count
        onProgress(alreadyMatched, total)

        guard !pendingIndices.isEmpty else {
            return updated
        }

        let maxConcurrent = 4
        var completed = 0
        var nextPendingCursor = 0

        await withTaskGroup(of: (Int, ImportedTrackCandidate).self) { group in
            let initialCount = min(maxConcurrent, pendingIndices.count)
            for _ in 0..<initialCount {
                let idx = pendingIndices[nextPendingCursor]
                nextPendingCursor += 1
                let candidate = updated.candidates[idx]
                group.addTask {
                    let resolved = await Self.resolveSingleCandidate(candidate, innerTube: innerTube)
                    return (idx, resolved)
                }
            }

            for await (idx, resolved) in group {
                updated.candidates[idx] = resolved
                completed += 1
                onProgress(alreadyMatched + completed, total)

                if !Task.isCancelled && nextPendingCursor < pendingIndices.count {
                    let nextIdx = pendingIndices[nextPendingCursor]
                    nextPendingCursor += 1
                    let nextCandidate = updated.candidates[nextIdx]
                    group.addTask {
                        let nextResolved = await Self.resolveSingleCandidate(nextCandidate, innerTube: innerTube)
                        return (nextIdx, nextResolved)
                    }
                }
            }
        }

        return updated
    }

    public func searchMatches(
        for query: String,
        innerTube: InnerTubeServiceProtocol
    ) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let results = try? await innerTube.search(query: trimmed) else { return [] }
        return Self.collectCandidateTracks(from: results)
    }

    // MARK: - Platform Fetchers

    private func extractYouTubePlaylist(
        rawURL: String,
        platform: ImportPlatform,
        innerTube: InnerTubeServiceProtocol
    ) async throws -> ImportedPlaylistPreview {
        guard let url = Self.normalizedWebURL(from: rawURL) else {
            throw PlaylistImportError.invalidURL
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let listId = components?.queryItems?
            .first(where: { $0.name == "list" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let listId, !listId.isEmpty {
            let playlist: Playlist
            do {
                playlist = try await innerTube.fetchPlaylist(browseId: listId)
            } catch {
                throw PlaylistImportError.networkError(error.localizedDescription)
            }

            guard !playlist.tracks.isEmpty else {
                throw PlaylistImportError.emptyPlaylist
            }

            let candidates = playlist.tracks.enumerated().map { idx, track in
                ImportedTrackCandidate(
                    id: "yt_\(idx)_\(track.id)",
                    sourceTitle: track.title,
                    sourceArtist: track.artist,
                    sourceAlbum: track.album,
                    sourceDuration: track.duration,
                    matchedTrack: track,
                    isSelected: true,
                    matchScore: 1.0,
                    status: .matched
                )
            }

            return ImportedPlaylistPreview(
                platform: platform,
                title: playlist.title.isEmpty ? "YouTube Playlist" : playlist.title,
                author: playlist.author,
                artworkURL: playlist.artworkURL ?? playlist.tracks.first?.artworkURL,
                sourceURL: rawURL,
                candidates: candidates
            )
        }

        // Fallback for /browse/<browseId> URLs
        let pathParts = url.pathComponents.filter { $0 != "/" }
        if let browseIdx = pathParts.firstIndex(of: "browse"), browseIdx + 1 < pathParts.count {
            let browseId = pathParts[browseIdx + 1]
            if browseId.hasPrefix("MPRE") {
                let album = try await innerTube.fetchAlbum(browseId: browseId)
                guard !album.tracks.isEmpty else { throw PlaylistImportError.emptyPlaylist }
                let candidates = album.tracks.enumerated().map { idx, track in
                    ImportedTrackCandidate(
                        id: "yt_\(idx)_\(track.id)",
                        sourceTitle: track.title,
                        sourceArtist: track.artist,
                        sourceAlbum: track.album ?? album.title,
                        sourceDuration: track.duration,
                        matchedTrack: track,
                        isSelected: true,
                        matchScore: 1.0,
                        status: .matched
                    )
                }
                return ImportedPlaylistPreview(
                    platform: platform,
                    title: album.title.isEmpty ? "YouTube Album" : album.title,
                    author: album.artist,
                    artworkURL: album.artworkURL ?? album.tracks.first?.artworkURL,
                    sourceURL: rawURL,
                    candidates: candidates
                )
            } else if !browseId.isEmpty {
                let playlist = try await innerTube.fetchPlaylist(browseId: browseId)
                guard !playlist.tracks.isEmpty else { throw PlaylistImportError.emptyPlaylist }
                let candidates = playlist.tracks.enumerated().map { idx, track in
                    ImportedTrackCandidate(
                        id: "yt_\(idx)_\(track.id)",
                        sourceTitle: track.title,
                        sourceArtist: track.artist,
                        sourceAlbum: track.album,
                        sourceDuration: track.duration,
                        matchedTrack: track,
                        isSelected: true,
                        matchScore: 1.0,
                        status: .matched
                    )
                }
                return ImportedPlaylistPreview(
                    platform: platform,
                    title: playlist.title.isEmpty ? "YouTube Playlist" : playlist.title,
                    author: playlist.author,
                    artworkURL: playlist.artworkURL ?? playlist.tracks.first?.artworkURL,
                    sourceURL: rawURL,
                    candidates: candidates
                )
            }
        }

        throw PlaylistImportError.invalidURL
    }

    private func extractSpotifyPlaylist(rawURL: String) async throws -> ImportedPlaylistPreview {
        let resolvedURL: URL
        if rawURL.lowercased().hasPrefix("spotify:") {
            let parts = rawURL.split(separator: ":").map(String.init)
            guard parts.count >= 3, (parts[1] == "playlist" || parts[1] == "album") else {
                throw PlaylistImportError.invalidURL
            }
            guard let constructed = URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])") else {
                throw PlaylistImportError.invalidURL
            }
            resolvedURL = constructed
        } else {
            guard var initialURL = Self.normalizedWebURL(from: rawURL) else {
                throw PlaylistImportError.invalidURL
            }
            if let host = initialURL.host?.lowercased(), host.contains("spotify.link") {
                let (_, finalURL) = try await fetchText(url: initialURL)
                initialURL = finalURL
            }
            resolvedURL = initialURL
        }

        guard let (kind, id) = Self.extractSpotifyKindAndID(from: resolvedURL) else {
            throw PlaylistImportError.invalidURL
        }

        let embedURLString = "https://open.spotify.com/embed/\(kind)/\(id)"
        guard let embedURL = URL(string: embedURLString) else {
            throw PlaylistImportError.invalidURL
        }

        do {
            let (embedHTML, _) = try await fetchText(url: embedURL)
            if let parsed = try? Self.parseSpotifyEmbedHTML(embedHTML, sourceURL: rawURL),
               !parsed.candidates.isEmpty {
                return parsed
            }
        } catch let importError as PlaylistImportError {
            if case .gatedPlatform = importError {
                throw importError
            }
        } catch {
            // Fall through to main page fallback below
        }

        // Fallback: fetch public main page and look for embedded JSON / NEXT_DATA / JSON-LD
        let mainURLString = "https://open.spotify.com/\(kind)/\(id)"
        guard let mainURL = URL(string: mainURLString) else {
            throw PlaylistImportError.invalidURL
        }
        let (mainHTML, _) = try await fetchText(url: mainURL)
        return try Self.parseSpotifyEmbedHTML(mainHTML, sourceURL: rawURL)
    }

    private func extractAppleMusicPlaylist(rawURL: String) async throws -> ImportedPlaylistPreview {
        guard let url = Self.normalizedWebURL(from: rawURL) else {
            throw PlaylistImportError.invalidURL
        }
        let pathLower = url.path.lowercased()
        guard pathLower.contains("/playlist/") || pathLower.contains("/album/") else {
            throw PlaylistImportError.invalidURL
        }

        let (html, _) = try await fetchText(url: url)
        return try Self.parseAppleMusicHTML(html, sourceURL: rawURL)
    }

    private func extractDeezerPlaylist(rawURL: String) async throws -> ImportedPlaylistPreview {
        guard var url = Self.normalizedWebURL(from: rawURL) else {
            throw PlaylistImportError.invalidURL
        }
        if let host = url.host?.lowercased(), host == "dzr.page.link" || host == "deezer.page.link" {
            let (_, redirected) = try await fetchText(url: url)
            url = redirected
        }

        guard let (kind, numericId) = Self.extractDeezerKindAndID(from: url) else {
            throw PlaylistImportError.invalidURL
        }

        guard let apiURL = URL(string: "https://api.deezer.com/\(kind)/\(numericId)") else {
            throw PlaylistImportError.invalidURL
        }

        let (initialData, _) = try await fetchData(url: apiURL)
        var preview = try Self.parseDeezerJSON(initialData, sourceURL: rawURL)

        // Follow tracks.next pagination up to 300 tracks
        if let root = try? JSONSerialization.jsonObject(with: initialData) as? [String: Any],
           let tracksObj = root["tracks"] as? [String: Any] {
            var nextURLString = tracksObj["next"] as? String
            var visitedURLs = Set<String>()
            let maxTracks = 300

            while let nextStr = nextURLString,
                  preview.candidates.count < maxTracks,
                  visitedURLs.insert(nextStr).inserted,
                  let nextURL = URL(string: nextStr) {
                guard let (pageData, _) = try? await fetchData(url: nextURL),
                      let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                    break
                }
                let pageItems = pageJSON["data"] as? [[String: Any]] ?? []
                if pageItems.isEmpty { break }

                let fallbackAlbum = kind == "album" ? preview.title : nil
                let fallbackArtist = preview.author ?? ""
                let baseIndex = preview.candidates.count

                for (offset, item) in pageItems.enumerated() {
                    if preview.candidates.count >= maxTracks { break }
                    if let candidate = Self.makeDeezerCandidate(
                        from: item,
                        index: baseIndex + offset,
                        fallbackArtist: fallbackArtist,
                        fallbackAlbum: fallbackAlbum
                    ) {
                        preview.candidates.append(candidate)
                    }
                }
                nextURLString = pageJSON["next"] as? String
            }
        }

        guard !preview.candidates.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }
        return preview
    }

    private func extractSoundCloudPlaylist(rawURL: String) async throws -> ImportedPlaylistPreview {
        guard var url = Self.normalizedWebURL(from: rawURL) else {
            throw PlaylistImportError.invalidURL
        }
        if let host = url.host?.lowercased(), host == "on.soundcloud.com" {
            let (_, redirected) = try await fetchText(url: url)
            url = redirected
        }

        let (html, _) = try await fetchText(url: url)
        return try Self.parseSoundCloudHTML(html, sourceURL: rawURL)
    }

    private func extractTidalPlaylist(rawURL: String) async throws -> ImportedPlaylistPreview {
        guard let url = Self.normalizedWebURL(from: rawURL) else {
            throw PlaylistImportError.invalidURL
        }

        let fetchURL: URL = {
            if let host = url.host?.lowercased(), host == "listen.tidal.com" {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.host = "tidal.com"
                if !url.path.hasPrefix("/browse") {
                    comps?.path = "/browse" + url.path
                }
                return comps?.url ?? url
            }
            return url
        }()

        let (data, httpResponse) = try await fetchRawResponse(url: fetchURL)
        if let status = httpResponse?.statusCode, [401, 403, 429, 503].contains(status) {
            throw PlaylistImportError.gatedPlatform(Self.tidalGatedMessage)
        }

        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return try Self.parseTidalHTML(html, sourceURL: rawURL)
    }

    // MARK: - Offline Parsers (Testable Without Network)

    public static func parseSpotifyEmbedHTML(
        _ html: String,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        if looksLikeGatePage(html) {
            throw PlaylistImportError.gatedPlatform(
                "Spotify blocked automated access for this link. Try again or export the playlist as CSV and use M3U / CSV import."
            )
        }

        // 1. Primary: <script id="__NEXT_DATA__">
        if let nextDataString = extractScriptTagContent(in: html, matchingID: "__NEXT_DATA__"),
           let data = nextDataString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let preview = parseSpotifyNextData(json, html: html, sourceURL: sourceURL) {
                return preview
            }
        }

        // 2. Fallback: base64 or JSON <script id="initialState"> / <script id="initial-state">
        for stateId in ["initialState", "initial-state"] {
            if let rawState = extractScriptTagContent(in: html, matchingID: stateId) {
                let cleaned = rawState.trimmingCharacters(in: .whitespacesAndNewlines)
                let stateData: Data? = Data(base64Encoded: cleaned) ?? cleaned.data(using: .utf8)
                if let stateData,
                   let json = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
                   let preview = parseSpotifyNextData(json, html: html, sourceURL: sourceURL) {
                    return preview
                }
            }
        }

        // 3. Fallback: embedded trackList JSON inside inline script
        if let trackListJSON = extractJSONArray(afterKey: "\"trackList\"", in: html),
           let data = trackListJSON.data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let candidates = makeSpotifyTrackListCandidates(from: items)
            if !candidates.isEmpty {
                let title = extractMetaContent(in: html, property: "og:title") ?? "Spotify Playlist"
                let art = extractMetaContent(in: html, property: "og:image").flatMap(URL.init(string:))
                return ImportedPlaylistPreview(
                    platform: .spotify,
                    title: cleanSpotifyTitle(decodeHTMLEntities(title)),
                    artworkURL: art,
                    sourceURL: sourceURL,
                    candidates: candidates
                )
            }
        }

        // 4. Fallback: JSON-LD
        if let ldPreview = parseJSONLDPlaylist(in: html, platform: .spotify, sourceURL: sourceURL) {
            return ldPreview
        }

        throw PlaylistImportError.emptyPlaylist
    }

    public static func parseAppleMusicHTML(
        _ html: String,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        // 1. Primary: <script type="application/ld+json">
        if let ldPreview = parseJSONLDPlaylist(in: html, platform: .appleMusic, sourceURL: sourceURL) {
            return ldPreview
        }

        // 2. Fallback: <script type="application/json" id="serialized-server-data">
        if let serialized = extractScriptTagContent(in: html, matchingID: "serialized-server-data"),
           let data = serialized.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            if let preview = parseAppleMusicSerializedServerData(root, html: html, sourceURL: sourceURL) {
                return preview
            }
        }

        throw PlaylistImportError.emptyPlaylist
    }

    public static func parseDeezerJSON(
        _ data: Data,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaylistImportError.networkError("Invalid JSON response from Deezer.")
        }

        if let errorObj = root["error"] as? [String: Any] {
            let msg = (errorObj["message"] as? String) ?? "Deezer API returned an error."
            throw PlaylistImportError.networkError(msg)
        }

        let title = ((root["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recordType = (root["record_type"] as? String) ?? (root["type"] as? String) ?? ""
        let isAlbum = recordType.lowercased() == "album" || root["artist"] != nil

        let author: String? = {
            if let creator = root["creator"] as? [String: Any], let name = creator["name"] as? String, !name.isEmpty {
                return name
            }
            if let artist = root["artist"] as? [String: Any], let name = artist["name"] as? String, !name.isEmpty {
                return name
            }
            return nil
        }()

        let artworkURL: URL? = {
            let keys = ["picture_xl", "picture_big", "cover_xl", "cover_big", "picture_medium", "cover_medium", "picture", "cover"]
            for key in keys {
                if let urlStr = root[key] as? String, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    return url
                }
            }
            return nil
        }()

        let tracksDict = root["tracks"] as? [String: Any]
        let trackItems = (tracksDict?["data"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []

        let fallbackAlbum = isAlbum && !title.isEmpty ? title : nil
        let fallbackArtist = author ?? ""

        var candidates: [ImportedTrackCandidate] = []
        candidates.reserveCapacity(trackItems.count)
        for (idx, item) in trackItems.enumerated() {
            if let candidate = makeDeezerCandidate(
                from: item,
                index: idx,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum
            ) {
                candidates.append(candidate)
            }
        }

        guard !candidates.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        return ImportedPlaylistPreview(
            platform: .deezer,
            title: title.isEmpty ? "Deezer Playlist" : title,
            author: author,
            artworkURL: artworkURL,
            sourceURL: sourceURL,
            candidates: candidates
        )
    }

    public static func parseDeezerJSON(
        _ jsonString: String,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        guard let data = jsonString.data(using: .utf8) else {
            throw PlaylistImportError.networkError("Invalid UTF-8 JSON string.")
        }
        return try parseDeezerJSON(data, sourceURL: sourceURL)
    }

    public static func parseSoundCloudHTML(
        _ html: String,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        if let hydrationJSON = extractSoundCloudHydrationJSON(from: html),
           let data = hydrationJSON.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var soundsById: [Int: [String: Any]] = [:]
            var playlistData: [String: Any]?
            var fallbackSoundData: [String: Any]?

            for entry in entries {
                let kind = (entry["hydratable"] as? String)?.lowercased() ?? ""
                guard let obj = entry["data"] as? [String: Any] else { continue }
                if kind == "sound", let idNum = (obj["id"] as? NSNumber)?.intValue {
                    soundsById[idNum] = obj
                    if fallbackSoundData == nil {
                        fallbackSoundData = obj
                    }
                } else if kind == "playlist" {
                    playlistData = obj
                } else if playlistData == nil, obj["tracks"] is [[String: Any]] {
                    playlistData = obj
                }
            }

            if let playlistData {
                let rawTitle = (playlistData["title"] as? String) ?? ""
                let title = decodeHTMLEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                let userObj = playlistData["user"] as? [String: Any]
                let author = (userObj?["username"] as? String).map(decodeHTMLEntities)
                let artStr = (playlistData["artwork_url"] as? String) ?? (userObj?["avatar_url"] as? String)
                let artworkURL = artStr.flatMap { URL(string: $0.replacingOccurrences(of: "-large.", with: "-t500x500.")) }

                let rawTracks = (playlistData["tracks"] as? [[String: Any]]) ?? []
                var candidates: [ImportedTrackCandidate] = []
                var missingStubCount = 0

                for (idx, rawTrack) in rawTracks.enumerated() {
                    var merged = rawTrack
                    if (merged["title"] as? String)?.isEmpty ?? true,
                       let idNum = (merged["id"] as? NSNumber)?.intValue,
                       let full = soundsById[idNum] {
                        merged = full
                    }

                    guard let trackTitle = (merged["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !trackTitle.isEmpty else {
                        missingStubCount += 1
                        continue
                    }

                    let pubMeta = merged["publisher_metadata"] as? [String: Any]
                    let trackUser = merged["user"] as? [String: Any]
                    let artistCandidate =
                        nonEmptyString(pubMeta?["artist"] as? String) ??
                        nonEmptyString(trackUser?["username"] as? String) ??
                        nonEmptyString(author) ??
                        ""
                    let albumTitle = nonEmptyString(pubMeta?["album_title"] as? String)
                    let durationRaw = (merged["duration"] as? NSNumber)?.doubleValue ?? 0
                    let duration = durationRaw > 1000 ? durationRaw / 1000.0 : durationRaw

                    candidates.append(
                        ImportedTrackCandidate(
                            id: "sc_\(idx)_\((merged["id"] as? NSNumber)?.stringValue ?? UUID().uuidString)",
                            sourceTitle: decodeHTMLEntities(trackTitle),
                            sourceArtist: decodeHTMLEntities(artistCandidate),
                            sourceAlbum: albumTitle.map(decodeHTMLEntities),
                            sourceDuration: duration,
                            status: .pending
                        )
                    )
                }

                if !candidates.isEmpty {
                    let warning: String? = missingStubCount > 0
                        ? "SoundCloud exposed \(candidates.count) tracks (\(missingStubCount) additional tracks lacked public metadata)."
                        : nil
                    return ImportedPlaylistPreview(
                        platform: .soundcloud,
                        title: title.isEmpty ? "SoundCloud Playlist" : title,
                        author: author,
                        artworkURL: artworkURL,
                        sourceURL: sourceURL,
                        candidates: candidates,
                        warningNote: warning
                    )
                }
            } else if let sound = fallbackSoundData,
                      let trackTitle = nonEmptyString(sound["title"] as? String) {
                let pubMeta = sound["publisher_metadata"] as? [String: Any]
                let trackUser = sound["user"] as? [String: Any]
                let artist = nonEmptyString(pubMeta?["artist"] as? String) ?? nonEmptyString(trackUser?["username"] as? String) ?? ""
                let durationRaw = (sound["duration"] as? NSNumber)?.doubleValue ?? 0
                let duration = durationRaw > 1000 ? durationRaw / 1000.0 : durationRaw
                let artStr = (sound["artwork_url"] as? String) ?? (trackUser?["avatar_url"] as? String)
                return ImportedPlaylistPreview(
                    platform: .soundcloud,
                    title: decodeHTMLEntities(trackTitle),
                    author: artist.isEmpty ? nil : decodeHTMLEntities(artist),
                    artworkURL: artStr.flatMap(URL.init(string:)),
                    sourceURL: sourceURL,
                    candidates: [
                        ImportedTrackCandidate(
                            id: "sc_0_\((sound["id"] as? NSNumber)?.stringValue ?? UUID().uuidString)",
                            sourceTitle: decodeHTMLEntities(trackTitle),
                            sourceArtist: decodeHTMLEntities(artist),
                            sourceAlbum: nonEmptyString(pubMeta?["album_title"] as? String).map(decodeHTMLEntities),
                            sourceDuration: duration,
                            status: .pending
                        )
                    ]
                )
            }
        }

        // Fallback: JSON-LD
        if let ldPreview = parseJSONLDPlaylist(in: html, platform: .soundcloud, sourceURL: sourceURL) {
            return ldPreview
        }

        throw PlaylistImportError.emptyPlaylist
    }

    public static func parseTidalHTML(
        _ html: String,
        sourceURL: String = ""
    ) throws -> ImportedPlaylistPreview {
        if looksLikeGatePage(html) {
            throw PlaylistImportError.gatedPlatform(tidalGatedMessage)
        }

        if let ldPreview = parseJSONLDPlaylist(in: html, platform: .tidal, sourceURL: sourceURL),
           !ldPreview.candidates.isEmpty {
            return ldPreview
        }

        throw PlaylistImportError.gatedPlatform(tidalGatedMessage)
    }

    public static func parseM3UContent(
        _ content: String,
        sourceURL: String = "",
        defaultTitle: String = "Imported Playlist"
    ) throws -> ImportedPlaylistPreview {
        let stripped = stripUTF8BOM(content)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = stripped.components(separatedBy: "\n")

        var playlistTitle = defaultTitle
        var pendingDuration: TimeInterval = 0
        var pendingArtist: String?
        var pendingTitle: String?
        var hasPendingExtinf = false
        var candidates: [ImportedTrackCandidate] = []

        func flushPending(fileLine: String?) {
            var resolvedTitle = pendingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var resolvedArtist = pendingArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if resolvedTitle.isEmpty, let fileLine {
                let parsed = parseArtistAndTitleFromFilePath(fileLine)
                resolvedArtist = parsed.artist
                resolvedTitle = parsed.title
            }

            if !resolvedTitle.isEmpty {
                let idx = candidates.count
                candidates.append(
                    ImportedTrackCandidate(
                        id: "m3u_\(idx)_\(UUID().uuidString)",
                        sourceTitle: resolvedTitle,
                        sourceArtist: resolvedArtist,
                        sourceAlbum: nil,
                        sourceDuration: max(0, pendingDuration),
                        status: .pending
                    )
                )
            }
            pendingDuration = 0
            pendingArtist = nil
            pendingTitle = nil
            hasPendingExtinf = false
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#PLAYLIST:") {
                    let value = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        playlistTitle = value
                    }
                } else if line.uppercased().hasPrefix("#EXTINF:") {
                    if hasPendingExtinf {
                        flushPending(fileLine: nil)
                    }
                    let payload = String(line.dropFirst("#EXTINF:".count))
                    if let commaIdx = payload.firstIndex(of: ",") {
                        let metaPart = String(payload[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let durationToken = metaPart.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "0"
                        let parsedDuration = Double(durationToken) ?? 0
                        pendingDuration = parsedDuration > 0 ? parsedDuration : 0

                        let display = String(payload[payload.index(after: commaIdx)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let split = splitArtistAndTitle(display)
                        pendingArtist = split.artist
                        pendingTitle = split.title
                    } else {
                        let parsedDuration = Double(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                        pendingDuration = parsedDuration > 0 ? parsedDuration : 0
                    }
                    hasPendingExtinf = true
                }
                continue
            }

            flushPending(fileLine: line)
        }

        if hasPendingExtinf {
            flushPending(fileLine: nil)
        }

        guard !candidates.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        return ImportedPlaylistPreview(
            platform: .localFile,
            title: playlistTitle,
            author: nil,
            artworkURL: nil,
            sourceURL: sourceURL,
            candidates: candidates
        )
    }

    public static func parseCSVContent(
        _ content: String,
        sourceURL: String = "",
        defaultTitle: String = "Imported Playlist"
    ) throws -> ImportedPlaylistPreview {
        let normalized = stripUTF8BOM(content)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let firstLine = normalized.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let delimiter: Character = {
            if firstLine.contains(",") { return "," }
            if firstLine.contains(";") { return ";" }
            if firstLine.contains("\t") { return "\t" }
            return ","
        }()

        let rows = parseRFC4180CSV(normalized, delimiter: delimiter)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        let normalizedHeaders = headerRow.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func findColumn(_ aliases: [String]) -> Int? {
            for alias in aliases {
                if let idx = normalizedHeaders.firstIndex(of: alias) {
                    return idx
                }
            }
            for alias in aliases {
                if let idx = normalizedHeaders.firstIndex(where: { $0.contains(alias) }) {
                    return idx
                }
            }
            return nil
        }

        let titleCol = findColumn(["track name", "title", "track", "song name", "song", "name"])
        let artistCol = findColumn(["artist name(s)", "artist names", "artist name", "artists", "artist", "artist(s)"])
        let albumCol = findColumn(["album name", "album", "album_name"])
        let durationCol = findColumn(["duration (ms)", "track duration (ms)", "duration_ms", "duration ms", "duration", "duration (s)", "length", "time"])

        guard let titleCol else {
            throw PlaylistImportError.emptyPlaylist
        }

        let durationHeaderIsMs = durationCol.map { normalizedHeaders[$0].contains("ms") } ?? false
        let durationHeaderIsSec = durationCol.map {
            let h = normalizedHeaders[$0]
            return h.contains("(s)") || h.contains("sec")
        } ?? false

        var candidates: [ImportedTrackCandidate] = []
        for (rowIdx, row) in rows.dropFirst().enumerated() {
            guard titleCol < row.count else { continue }
            let rawTitle = row[titleCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else { continue }

            let rawArtist: String = {
                guard let artistCol, artistCol < row.count else { return "" }
                let value = row[artistCol].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.replacingOccurrences(of: ";", with: ", ")
            }()

            let rawAlbum: String? = {
                guard let albumCol, albumCol < row.count else { return nil }
                let value = row[albumCol].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }()

            let duration: TimeInterval = {
                guard let durationCol, durationCol < row.count else { return 0 }
                let value = row[durationCol].trimmingCharacters(in: .whitespacesAndNewlines)
                return parseCSVDuration(value, headerIsMs: durationHeaderIsMs, headerIsSec: durationHeaderIsSec)
            }()

            candidates.append(
                ImportedTrackCandidate(
                    id: "csv_\(rowIdx)_\(UUID().uuidString)",
                    sourceTitle: rawTitle,
                    sourceArtist: rawArtist,
                    sourceAlbum: rawAlbum,
                    sourceDuration: duration,
                    status: .pending
                )
            )
        }

        guard !candidates.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        return ImportedPlaylistPreview(
            platform: .localFile,
            title: defaultTitle,
            author: nil,
            artworkURL: nil,
            sourceURL: sourceURL,
            candidates: candidates
        )
    }

    // MARK: - Scoring & InnerTube Matching Helpers

    public static func scoreMatch(candidate: ImportedTrackCandidate, track: Track) -> Double {
        let candidateTitle = cleanNormalizedTokens(candidate.sourceTitle, stripNoiseTags: true)
        let trackTitle = cleanNormalizedTokens(track.title, stripNoiseTags: true)

        let titleScore = tokenSimilarity(candidateTitle, trackTitle)

        let artistScore: Double = {
            let cleanCandArtist = cleanNormalizedTokens(candidate.sourceArtist, stripNoiseTags: false)
            if cleanCandArtist.isEmpty {
                return 0.55
            }
            let cleanTrackArtist = cleanNormalizedTokens(track.artist, stripNoiseTags: false)
            let direct = tokenSimilarity(cleanCandArtist, cleanTrackArtist)
            if direct > 0 {
                return direct
            }
            // Sometimes YouTube video results embed the artist in the track title ("Artist - Title")
            let rawTrackTokens = cleanNormalizedTokens("\(track.artist) \(track.title)", stripNoiseTags: false)
            return tokenSimilarity(cleanCandArtist, rawTrackTokens) * 0.8
        }()

        let durationScore: Double = {
            guard candidate.sourceDuration > 0, track.duration > 0 else {
                return 0.5
            }
            let diff = abs(candidate.sourceDuration - track.duration)
            if diff <= 3.0 { return 1.0 }
            if diff <= 10.0 { return 1.0 - ((diff - 3.0) / 7.0) * 0.45 }
            if diff <= 20.0 { return 0.25 }
            return 0.0
        }()

        var total = (titleScore * 0.55) + (artistScore * 0.30) + (durationScore * 0.15)
        if titleScore < 0.25 {
            total = min(total, 0.34)
        }
        return max(0.0, min(1.0, total))
    }

    private static func resolveSingleCandidate(
        _ candidate: ImportedTrackCandidate,
        innerTube: InnerTubeServiceProtocol
    ) async -> ImportedTrackCandidate {
        var result = candidate
        let query = candidate.sourceArtist.isEmpty
            ? candidate.sourceTitle
            : "\(candidate.sourceTitle) \(candidate.sourceArtist)"

        var tracks = await performSafeSearch(query: query, innerTube: innerTube)

        if tracks.isEmpty {
            let simplifiedTitle = stripParentheticalNoise(candidate.sourceTitle)
            if simplifiedTitle != candidate.sourceTitle && !simplifiedTitle.isEmpty {
                let fallbackQuery = candidate.sourceArtist.isEmpty
                    ? simplifiedTitle
                    : "\(simplifiedTitle) \(candidate.sourceArtist)"
                tracks = await performSafeSearch(query: fallbackQuery, innerTube: innerTube)
            }
        }

        var bestTrack: Track?
        var bestScore = 0.0
        for track in tracks {
            let score = scoreMatch(candidate: candidate, track: track)
            if score > bestScore {
                bestScore = score
                bestTrack = track
            }
        }

        if let bestTrack, bestScore >= 0.45 {
            result.matchedTrack = bestTrack
            result.matchScore = bestScore
            result.status = .matched
            result.isSelected = true
        } else {
            result.matchedTrack = nil
            result.matchScore = bestScore
            result.status = .notFound
            result.isSelected = false
        }
        return result
    }

    private static func performSafeSearch(
        query: String,
        innerTube: InnerTubeServiceProtocol
    ) async -> [Track] {
        guard !Task.isCancelled else { return [] }
        guard let results = try? await innerTube.search(query: query) else {
            return []
        }
        return collectCandidateTracks(from: results)
    }

    private static func collectCandidateTracks(from results: SearchResults) -> [Track] {
        var tracks: [Track] = []
        var seen = Set<String>()

        if case .track(let topTrack) = results.topResult,
           seen.insert(topTrack.videoId).inserted {
            tracks.append(topTrack)
        }

        for song in results.songs where seen.insert(song.videoId).inserted {
            tracks.append(song)
        }
        return tracks
    }

    // MARK: - Networking

    private func fetchText(url: URL) async throws -> (String, URL) {
        let (data, response) = try await fetchRawResponse(url: url)
        if let http = response, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 {
                throw PlaylistImportError.networkError("Playlist not found (HTTP 404). Make sure the playlist is public.")
            }
            throw PlaylistImportError.networkError("HTTP \(http.statusCode) while loading \(url.host ?? "playlist").")
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return (text, response?.url ?? url)
    }

    private func fetchData(url: URL) async throws -> (Data, URL) {
        let (data, response) = try await fetchRawResponse(url: url)
        if let http = response, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 {
                throw PlaylistImportError.networkError("Playlist not found (HTTP 404).")
            }
            throw PlaylistImportError.networkError("HTTP \(http.statusCode) while loading \(url.host ?? "API").")
        }
        return (data, response?.url ?? url)
    }

    private func fetchRawResponse(url: URL) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch let err as PlaylistImportError {
            throw err
        } catch {
            throw PlaylistImportError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Spotify Parsing Helpers

    private static func parseSpotifyNextData(
        _ json: [String: Any],
        html: String,
        sourceURL: String
    ) -> ImportedPlaylistPreview? {
        let entity: [String: Any]? = {
            if let props = json["props"] as? [String: Any],
               let pageProps = props["pageProps"] as? [String: Any],
               let state = pageProps["state"] as? [String: Any],
               let data = state["data"] as? [String: Any],
               let e = data["entity"] as? [String: Any] {
                return e
            }
            if let e = json["entity"] as? [String: Any] {
                return e
            }
            if json["trackList"] != nil || json["tracks"] != nil {
                return json
            }
            return nil
        }()

        guard let entity else { return nil }

        let rawTitle = (entity["name"] as? String)
            ?? (entity["title"] as? String)
            ?? extractMetaContent(in: html, property: "og:title")
            ?? "Spotify Playlist"
        let title = cleanSpotifyTitle(decodeHTMLEntities(rawTitle))

        let author: String? = {
            if let sub = nonEmptyString(entity["subtitle"] as? String) {
                return decodeHTMLEntities(sub)
            }
            if let ownerV2 = entity["ownerV2"] as? [String: Any],
               let data = ownerV2["data"] as? [String: Any],
               let name = nonEmptyString(data["name"] as? String) {
                return decodeHTMLEntities(name)
            }
            if let artists = entity["artists"] as? [[String: Any]] {
                let names = artists.compactMap { nonEmptyString($0["name"] as? String) }
                if !names.isEmpty { return decodeHTMLEntities(names.joined(separator: ", ")) }
            }
            return nil
        }()

        let artworkURL: URL? = {
            if let coverArt = entity["coverArt"] as? [String: Any],
               let sources = coverArt["sources"] as? [[String: Any]],
               let best = pickLargestImageURL(from: sources) {
                return best
            }
            if let visual = entity["visualIdentity"] as? [String: Any],
               let images = visual["image"] as? [[String: Any]],
               let best = pickLargestImageURL(from: images) {
                return best
            }
            if let images = entity["images"] as? [[String: Any]],
               let best = pickLargestImageURL(from: images) {
                return best
            }
            return extractMetaContent(in: html, property: "og:image").flatMap(URL.init(string:))
        }()

        var candidates: [ImportedTrackCandidate] = []
        if let trackList = entity["trackList"] as? [[String: Any]] {
            candidates = makeSpotifyTrackListCandidates(from: trackList)
        } else if let tracksObj = entity["tracks"] as? [String: Any],
                  let items = tracksObj["items"] as? [[String: Any]] {
            let albumFallback = (entity["type"] as? String) == "album" ? title : nil
            candidates = makeSpotifyWebAPITrackCandidates(from: items, fallbackAlbum: albumFallback)
        }

        guard !candidates.isEmpty else { return nil }

        return ImportedPlaylistPreview(
            platform: .spotify,
            title: title.isEmpty ? "Spotify Playlist" : title,
            author: author,
            artworkURL: artworkURL,
            sourceURL: sourceURL,
            candidates: candidates
        )
    }

    private static func makeSpotifyTrackListCandidates(from trackList: [[String: Any]]) -> [ImportedTrackCandidate] {
        var candidates: [ImportedTrackCandidate] = []
        candidates.reserveCapacity(trackList.count)

        for (idx, item) in trackList.enumerated() {
            let rawTitle = nonEmptyString(item["title"] as? String) ?? nonEmptyString(item["name"] as? String)
            guard let rawTitle else { continue }

            let artist: String = {
                if let subtitle = nonEmptyString(item["subtitle"] as? String) {
                    return decodeHTMLEntities(subtitle.replacingOccurrences(of: "\u{00A0}", with: " "))
                }
                if let artists = item["artists"] as? [[String: Any]] {
                    let names = artists.compactMap { nonEmptyString($0["name"] as? String) }
                    return decodeHTMLEntities(names.joined(separator: ", "))
                }
                return ""
            }()

            let durationRaw = (item["duration"] as? NSNumber)?.doubleValue
                ?? (item["duration_ms"] as? NSNumber)?.doubleValue
                ?? 0
            let duration = durationRaw > 1000 ? durationRaw / 1000.0 : durationRaw

            let trackId = nonEmptyString(item["uid"] as? String)
                ?? nonEmptyString(item["uri"] as? String)
                ?? "\(idx)_\(UUID().uuidString)"

            candidates.append(
                ImportedTrackCandidate(
                    id: "sp_\(trackId)",
                    sourceTitle: decodeHTMLEntities(rawTitle),
                    sourceArtist: artist,
                    sourceAlbum: nonEmptyString(item["albumName"] as? String).map(decodeHTMLEntities),
                    sourceDuration: duration,
                    status: .pending
                )
            )
        }
        return candidates
    }

    private static func makeSpotifyWebAPITrackCandidates(
        from items: [[String: Any]],
        fallbackAlbum: String?
    ) -> [ImportedTrackCandidate] {
        var candidates: [ImportedTrackCandidate] = []
        for (idx, rawItem) in items.enumerated() {
            let track = (rawItem["track"] as? [String: Any]) ?? rawItem
            guard let name = nonEmptyString(track["name"] as? String) ?? nonEmptyString(track["title"] as? String) else {
                continue
            }
            let artists = (track["artists"] as? [[String: Any]])?
                .compactMap { nonEmptyString($0["name"] as? String) }
                .joined(separator: ", ") ?? ""
            let albumName = ((track["album"] as? [String: Any])?["name"] as? String) ?? fallbackAlbum
            let durationRaw = (track["duration_ms"] as? NSNumber)?.doubleValue
                ?? (track["duration"] as? NSNumber)?.doubleValue
                ?? 0
            let duration = durationRaw > 1000 ? durationRaw / 1000.0 : durationRaw
            candidates.append(
                ImportedTrackCandidate(
                    id: "sp_\(idx)_\((track["id"] as? String) ?? UUID().uuidString)",
                    sourceTitle: decodeHTMLEntities(name),
                    sourceArtist: decodeHTMLEntities(artists),
                    sourceAlbum: albumName.map(decodeHTMLEntities),
                    sourceDuration: duration,
                    status: .pending
                )
            )
        }
        return candidates
    }

    // MARK: - JSON-LD & Apple Music Helpers

    private static func parseJSONLDPlaylist(
        in html: String,
        platform: ImportPlatform,
        sourceURL: String
    ) -> ImportedPlaylistPreview? {
        let blocks = extractAllScriptTagContents(in: html, matchingType: "application/ld+json")
        guard !blocks.isEmpty else { return nil }

        var candidateObjects: [[String: Any]] = []
        for block in blocks {
            guard let data = block.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            collectJSONObjects(from: parsed, into: &candidateObjects)
        }

        for obj in candidateObjects {
            let typeValue = ((obj["@type"] as? String) ?? "").lowercased()
            let typesArray = (obj["@type"] as? [String])?.map { $0.lowercased() } ?? []
            let isPlaylistOrAlbum = typeValue.contains("playlist") || typeValue.contains("album") ||
                typesArray.contains(where: { $0.contains("playlist") || $0.contains("album") })
            guard isPlaylistOrAlbum else { continue }

            let rawTracks = (obj["track"] as? [[String: Any]]) ?? (obj["tracks"] as? [[String: Any]]) ?? []
            if rawTracks.isEmpty { continue }

            let isAlbum = typeValue.contains("album") || typesArray.contains(where: { $0.contains("album") })
            let rawTitle = nonEmptyString(obj["name"] as? String)
                ?? extractMetaContent(in: html, property: "og:title")
                ?? "\(platform.displayName) Playlist"
            let title = decodeHTMLEntities(rawTitle)

            let author = extractJSONLDArtistName(from: obj["author"] ?? obj["byArtist"])
            let artworkURL = extractJSONLDImageURL(from: obj["image"])
                ?? extractMetaContent(in: html, property: "og:image").flatMap(URL.init(string:))

            var candidates: [ImportedTrackCandidate] = []
            for (idx, item) in rawTracks.enumerated() {
                let recording = (item["item"] as? [String: Any]) ?? item
                guard let trackName = nonEmptyString(recording["name"] as? String) else { continue }
                let trackArtist = extractJSONLDArtistName(from: recording["byArtist"] ?? recording["author"])
                    ?? author
                    ?? ""
                let trackAlbum: String? = {
                    if let inAlbum = recording["inAlbum"] as? [String: Any],
                       let name = nonEmptyString(inAlbum["name"] as? String) {
                        return decodeHTMLEntities(name)
                    }
                    if let albumStr = nonEmptyString(recording["inAlbum"] as? String) {
                        return decodeHTMLEntities(albumStr)
                    }
                    return isAlbum ? title : nil
                }()
                let duration = parseDurationValue(recording["duration"] ?? recording["durationInMillis"])

                candidates.append(
                    ImportedTrackCandidate(
                        id: "\(platform.rawValue)_\(idx)_\(UUID().uuidString)",
                        sourceTitle: decodeHTMLEntities(trackName),
                        sourceArtist: decodeHTMLEntities(trackArtist),
                        sourceAlbum: trackAlbum,
                        sourceDuration: duration,
                        status: .pending
                    )
                )
            }

            if !candidates.isEmpty {
                return ImportedPlaylistPreview(
                    platform: platform,
                    title: title,
                    author: author.map(decodeHTMLEntities),
                    artworkURL: artworkURL,
                    sourceURL: sourceURL,
                    candidates: candidates
                )
            }
        }

        return nil
    }

    private static func parseAppleMusicSerializedServerData(
        _ root: Any,
        html: String,
        sourceURL: String
    ) -> ImportedPlaylistPreview? {
        var tracks: [ImportedTrackCandidate] = []
        var foundTitle: String?
        var foundAuthor: String?
        var foundArtwork: URL?

        func walk(_ node: Any) {
            if let array = node as? [Any] {
                for item in array {
                    walk(item)
                }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            if foundTitle == nil,
               let header = dict["header"] as? [String: Any],
               let headerTitle = nonEmptyString(header["title"] as? String) {
                foundTitle = headerTitle
                if let sub = nonEmptyString(header["subtitle"] as? String) {
                    foundAuthor = sub
                }
                if let artDict = header["artwork"] as? [String: Any] {
                    foundArtwork = appleArtworkURL(from: artDict)
                }
            }

            // Detect Apple Music lockup / song attributes
            if let attrs = dict["attributes"] as? [String: Any],
               let songName = nonEmptyString(attrs["name"] as? String),
               attrs["durationInMillis"] != nil || (dict["type"] as? String) == "songs" {
                let artistName = nonEmptyString(attrs["artistName"] as? String) ?? ""
                let albumName = nonEmptyString(attrs["albumName"] as? String)
                let duration = parseDurationValue(attrs["durationInMillis"] ?? attrs["duration"])
                tracks.append(
                    ImportedTrackCandidate(
                        id: "am_\(tracks.count)_\(UUID().uuidString)",
                        sourceTitle: decodeHTMLEntities(songName),
                        sourceArtist: decodeHTMLEntities(artistName),
                        sourceAlbum: albumName.map(decodeHTMLEntities),
                        sourceDuration: duration,
                        status: .pending
                    )
                )
                return
            }

            if let trackTitle = nonEmptyString(dict["title"] as? String),
               (dict["duration"] != nil || dict["durationInMillis"] != nil || dict["trackNumber"] != nil) {
                let artist: String = {
                    if let artistName = nonEmptyString(dict["artistName"] as? String) {
                        return artistName
                    }
                    if let links = dict["subtitleLinks"] as? [[String: Any]] {
                        let names = links.compactMap { nonEmptyString($0["title"] as? String) }
                        if !names.isEmpty { return names.joined(separator: ", ") }
                    }
                    return ""
                }()
                let albumName = nonEmptyString(dict["albumName"] as? String)
                let duration = parseDurationValue(dict["durationInMillis"] ?? dict["duration"])
                tracks.append(
                    ImportedTrackCandidate(
                        id: "am_\(tracks.count)_\(UUID().uuidString)",
                        sourceTitle: decodeHTMLEntities(trackTitle),
                        sourceArtist: decodeHTMLEntities(artist),
                        sourceAlbum: albumName.map(decodeHTMLEntities),
                        sourceDuration: duration,
                        status: .pending
                    )
                )
                return
            }

            for value in dict.values {
                walk(value)
            }
        }

        walk(root)
        guard !tracks.isEmpty else { return nil }

        let title = foundTitle
            ?? extractMetaContent(in: html, property: "og:title")
            ?? "Apple Music Playlist"
        let artwork = foundArtwork
            ?? extractMetaContent(in: html, property: "og:image").flatMap(URL.init(string:))

        return ImportedPlaylistPreview(
            platform: .appleMusic,
            title: decodeHTMLEntities(title),
            author: foundAuthor.map(decodeHTMLEntities),
            artworkURL: artwork,
            sourceURL: sourceURL,
            candidates: tracks
        )
    }

    // MARK: - Deezer Helpers

    private static func makeDeezerCandidate(
        from item: [String: Any],
        index: Int,
        fallbackArtist: String,
        fallbackAlbum: String?
    ) -> ImportedTrackCandidate? {
        let rawTitle = nonEmptyString(item["title"] as? String) ?? nonEmptyString(item["title_short"] as? String)
        guard let rawTitle else { return nil }

        let artistName = ((item["artist"] as? [String: Any])?["name"] as? String) ?? fallbackArtist
        let albumTitle = ((item["album"] as? [String: Any])?["title"] as? String) ?? fallbackAlbum
        let duration = (item["duration"] as? NSNumber)?.doubleValue ?? 0
        let trackId = (item["id"] as? NSNumber)?.stringValue ?? UUID().uuidString

        return ImportedTrackCandidate(
            id: "dz_\(index)_\(trackId)",
            sourceTitle: rawTitle,
            sourceArtist: artistName,
            sourceAlbum: nonEmptyString(albumTitle),
            sourceDuration: max(0, duration),
            status: .pending
        )
    }

    // MARK: - URL Path Extraction Helpers

    private static func normalizedWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            withScheme = "https://" + trimmed
        } else {
            return nil
        }
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private static func stripCommonSubdomains(_ host: String) -> String {
        var result = host.lowercased()
        for prefix in ["www.", "m.", "open.", "play."] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
            }
        }
        return result
    }

    private static func extractSpotifyKindAndID(from url: URL) -> (kind: String, id: String)? {
        let components = url.pathComponents.filter { $0 != "/" }
        for (idx, part) in components.enumerated() {
            if (part == "playlist" || part == "album"), idx + 1 < components.count {
                let id = components[idx + 1]
                if !id.isEmpty {
                    return (part, id)
                }
            }
        }
        return nil
    }

    private static func extractDeezerKindAndID(from url: URL) -> (kind: String, id: String)? {
        let components = url.pathComponents.filter { $0 != "/" }
        for (idx, part) in components.enumerated() {
            if (part == "playlist" || part == "album"), idx + 1 < components.count {
                let id = components[idx + 1]
                if !id.isEmpty && id.allSatisfy(\.isNumber) {
                    return (part, id)
                }
            }
        }
        return nil
    }

    // MARK: - HTML / JSON Extraction Primitives

    private static func extractScriptTagContent(in html: String, matchingID targetID: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: targetID)
        let pattern = "<script[^>]*\\bid\\s*=\\s*[\"']\(escapedID)[\"'][^>]*>([\\s\\S]*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[contentRange])
    }

    private static func extractAllScriptTagContents(in html: String, matchingType targetType: String) -> [String] {
        let escapedType = NSRegularExpression.escapedPattern(for: targetType)
        let pattern = "<script[^>]*\\btype\\s*=\\s*[\"']\(escapedType)[\"'][^>]*>([\\s\\S]*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[contentRange])
        }
    }

    private static func extractSoundCloudHydrationJSON(from html: String) -> String? {
        guard let markerRange = html.range(of: "__sc_hydration") else { return nil }
        guard let eqRange = html.range(of: "=", range: markerRange.upperBound..<html.endIndex) else { return nil }
        return extractBalancedJSON(startingWith: "[", endingWith: "]", from: eqRange.upperBound, in: html)
    }

    private static func extractJSONArray(afterKey key: String, in html: String) -> String? {
        guard let keyRange = html.range(of: key) else { return nil }
        guard let colonRange = html.range(of: ":", range: keyRange.upperBound..<html.endIndex) else { return nil }
        return extractBalancedJSON(startingWith: "[", endingWith: "]", from: colonRange.upperBound, in: html)
    }

    private static func extractBalancedJSON(
        startingWith openChar: Character,
        endingWith closeChar: Character,
        from startIndex: String.Index,
        in text: String
    ) -> String? {
        var idx = startIndex
        while idx < text.endIndex && text[idx].isWhitespace {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == openChar else { return nil }

        let begin = idx
        var depth = 0
        var inString = false
        var escaped = false

        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == openChar {
                    depth += 1
                } else if ch == closeChar {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: idx)
                        return String(text[begin..<end])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func extractMetaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]*\\b(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>",
            "<meta[^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*\\b(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*>"
        ]
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let match = regex.firstMatch(in: html, options: [], range: nsRange),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return decodeHTMLEntities(value)
                }
            }
        }
        return nil
    }

    private static func looksLikeGatePage(_ html: String) -> Bool {
        let lower = html.lowercased()
        let markers = [
            "cf-browser-verification",
            "challenge-platform",
            "attention required! | cloudflare",
            "just a moment...",
            "enable javascript and cookies to continue"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    // MARK: - JSON-LD & Duration Helpers

    private static func collectJSONObjects(from value: Any, into results: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            results.append(dict)
            if let graph = dict["@graph"] as? [Any] {
                for item in graph {
                    collectJSONObjects(from: item, into: &results)
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectJSONObjects(from: item, into: &results)
            }
        }
    }

    private static func extractJSONLDArtistName(from value: Any?) -> String? {
        if let str = nonEmptyString(value as? String) {
            return str
        }
        if let dict = value as? [String: Any] {
            return nonEmptyString(dict["name"] as? String)
        }
        if let arr = value as? [[String: Any]] {
            let names = arr.compactMap { nonEmptyString($0["name"] as? String) }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }
        if let strArr = value as? [String] {
            let names = strArr.compactMap(nonEmptyString)
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }
        return nil
    }

    private static func extractJSONLDImageURL(from value: Any?) -> URL? {
        if let str = nonEmptyString(value as? String) {
            return URL(string: str)
        }
        if let arr = value as? [String], let first = arr.first {
            return URL(string: first)
        }
        if let dict = value as? [String: Any], let urlStr = nonEmptyString(dict["url"] as? String) {
            return URL(string: urlStr)
        }
        if let dictArr = value as? [[String: Any]], let first = dictArr.first, let urlStr = nonEmptyString(first["url"] as? String) {
            return URL(string: urlStr)
        }
        return nil
    }

    private static func appleArtworkURL(from dict: [String: Any]) -> URL? {
        if let dictionary = dict["dictionary"] as? [String: Any],
           let urlTemplate = nonEmptyString(dictionary["url"] as? String) {
            let resolved = urlTemplate
                .replacingOccurrences(of: "{w}", with: "600")
                .replacingOccurrences(of: "{h}", with: "600")
                .replacingOccurrences(of: "{f}", with: "jpg")
            return URL(string: resolved)
        }
        if let template = nonEmptyString(dict["url"] as? String) {
            let resolved = template
                .replacingOccurrences(of: "{w}", with: "600")
                .replacingOccurrences(of: "{h}", with: "600")
                .replacingOccurrences(of: "{f}", with: "jpg")
            return URL(string: resolved)
        }
        return nil
    }

    private static func pickLargestImageURL(from sources: [[String: Any]]) -> URL? {
        var bestURL: URL?
        var bestWidth = -1
        for src in sources {
            guard let urlStr = nonEmptyString(src["url"] as? String),
                  let url = URL(string: urlStr) else { continue }
            let width = (src["width"] as? NSNumber)?.intValue ?? 0
            if bestURL == nil || width > bestWidth {
                bestWidth = width
                bestURL = url
            }
        }
        return bestURL
    }

    private static func parseDurationValue(_ raw: Any?) -> TimeInterval {
        if let num = raw as? NSNumber {
            let val = num.doubleValue
            return val > 1000 ? val / 1000.0 : max(0, val)
        }
        guard let str = nonEmptyString(raw as? String) else { return 0 }
        let upper = str.uppercased()
        if upper.hasPrefix("PT") {
            return parseISO8601Duration(upper)
        }
        if let numeric = Double(str) {
            return numeric > 1000 ? numeric / 1000.0 : max(0, numeric)
        }
        return 0
    }

    private static func parseISO8601Duration(_ value: String) -> TimeInterval {
        let pattern = "^PT(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else {
            return 0
        }
        func component(_ idx: Int) -> Double {
            guard idx < match.numberOfRanges,
                  let r = Range(match.range(at: idx), in: value) else {
                return 0
            }
            return Double(value[r]) ?? 0
        }
        return component(1) * 3600 + component(2) * 60 + component(3)
    }

    // MARK: - M3U & CSV Parsing Helpers

    private static func stripUTF8BOM(_ text: String) -> String {
        if text.hasPrefix("\u{FEFF}") {
            return String(text.dropFirst())
        }
        return text
    }

    private static func splitArtistAndTitle(_ text: String) -> (artist: String, title: String) {
        for separator in [" - ", " \u{2013} "] {
            if let range = text.range(of: separator) {
                let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    return (left, right)
                }
            }
        }
        return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseArtistAndTitleFromFilePath(_ line: String) -> (artist: String, title: String) {
        let rawName: String
        if let url = URL(string: line), url.scheme != nil {
            rawName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
                ?? url.deletingPathExtension().lastPathComponent
        } else {
            rawName = URL(fileURLWithPath: line).deletingPathExtension().lastPathComponent
        }
        let cleaned = stripLeadingTrackNumber(rawName)
        return splitArtistAndTitle(cleaned)
    }

    private static func stripLeadingTrackNumber(_ name: String) -> String {
        let pattern = "^\\d{1,3}[\\.\\s_-]+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return name }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if let match = regex.firstMatch(in: name, options: [], range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: name) {
            return String(name[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
    }

    private static func parseRFC4180CSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var idx = text.startIndex

        while idx < text.endIndex {
            let ch = text[idx]
            if inQuotes {
                if ch == "\"" {
                    let nextIdx = text.index(after: idx)
                    if nextIdx < text.endIndex && text[nextIdx] == "\"" {
                        currentField.append("\"")
                        idx = text.index(after: nextIdx)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" && currentField.isEmpty {
                    inQuotes = true
                } else if ch == delimiter {
                    currentRow.append(currentField)
                    currentField = ""
                } else if ch == "\n" {
                    currentRow.append(currentField)
                    if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(ch)
                }
            }
            idx = text.index(after: idx)
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    private static func parseCSVDuration(
        _ raw: String,
        headerIsMs: Bool,
        headerIsSec: Bool
    ) -> TimeInterval {
        guard !raw.isEmpty else { return 0 }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                return max(0, parts[0] * 60 + parts[1])
            } else if parts.count == 3 {
                return max(0, parts[0] * 3600 + parts[1] * 60 + parts[2])
            }
        }
        guard let numeric = Double(raw), numeric > 0 else { return 0 }
        if headerIsMs {
            return numeric / 1000.0
        }
        if headerIsSec {
            return numeric
        }
        return numeric > 3600 ? numeric / 1000.0 : numeric
    }

    // MARK: - Text Normalization & Similarity Helpers

    private static func cleanNormalizedTokens(_ text: String, stripNoiseTags: Bool) -> [String] {
        var working = text
        if stripNoiseTags {
            working = stripParentheticalNoise(working)
        }
        let folded = working
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")

        let scalarFiltered = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let cleaned = String(scalarFiltered)
        let stopWords: Set<String> = stripNoiseTags
            ? ["official", "audio", "video", "lyric", "lyrics", "visualizer", "hd", "hq"]
            : []

        return cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !stopWords.contains($0) }
    }

    private static func stripParentheticalNoise(_ text: String) -> String {
        let pattern = "\\s*[\\(\\[](?:official|lyrics?|audio|video|hd|hq|remaster(?:ed)?|feat\\.?|ft\\.?|explicit|clean)[^\\)\\]]*[\\)\\]]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let joinedA = a.joined(separator: " ")
        let joinedB = b.joined(separator: " ")
        if joinedA == joinedB {
            return 1.0
        }

        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        let jaccard = union > 0 ? Double(intersection) / Double(union) : 0.0
        let containment = Double(intersection) / Double(min(setA.count, setB.count))
        let base = (jaccard * 0.65) + (containment * 0.35)

        if joinedA.contains(joinedB) || joinedB.contains(joinedA) {
            return max(base, 0.88)
        }
        return base
    }

    private static func cleanSpotifyTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" | Spotify", " - playlist by ", " - Album by "] {
            if let range = title.range(of: suffix) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return title
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#34;", "\""),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&ndash;", "-"),
            ("&mdash;", "-")
        ]
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode numeric decimal/hex entities like &#x2F; or &#8217;
        let pattern = "&#(x?[0-9A-Fa-f]+);"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let fullRange = Range(match.range(at: 0), in: result),
                      let codeRange = Range(match.range(at: 1), in: result) else {
                    continue
                }
                let codeStr = String(result[codeRange])
                let scalarValue: UInt32? = codeStr.lowercased().hasPrefix("x")
                    ? UInt32(codeStr.dropFirst(), radix: 16)
                    : UInt32(codeStr, radix: 10)
                if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }
        return result
    }

    private static func nonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
