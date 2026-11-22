import Foundation

// MARK: - Synced Lyrics Engine (Multi-Provider Parallel Fetcher + TTML/LRC Parsers + Translation)

public final class LyricsEngine: LyricsServiceProtocol, Sendable {
    private static let userAgent = "BitChord/1.0 (macOS)"
    private static let lyricsPlusMirrors: [String] = [
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.atomix.one"
    ]
    private static let cacheTTL: TimeInterval = 3600 * 12

    private let session: URLSession
    private let innerTube: InnerTubeClient
    private let cache: LyricsCache

    private actor LyricsCache {
        struct Entry {
            let document: LyricsDocument
            let cachedAt: Date
        }

        var lyrics: [String: Entry] = [:]
        var translations: [String: LyricsDocument] = [:]

        func getLyrics(key: String) -> LyricsDocument? {
            guard let entry = lyrics[key] else { return nil }
            if Date().timeIntervalSince(entry.cachedAt) > LyricsEngine.cacheTTL {
                lyrics.removeValue(forKey: key)
                return nil
            }
            return entry.document
        }

        func setLyrics(_ doc: LyricsDocument, for key: String) {
            if lyrics.count >= 150 {
                lyrics.removeAll(keepingCapacity: true)
            }
            lyrics[key] = Entry(document: doc, cachedAt: Date())
        }

        func getTranslation(key: String) -> LyricsDocument? {
            translations[key]
        }

        func setTranslation(_ doc: LyricsDocument, for key: String) {
            if translations.count >= 60 {
                translations.removeAll(keepingCapacity: true)
            }
            translations[key] = doc
        }
    }

    private struct Query: Sendable {
        let trackId: String
        let videoId: String
        let title: String
        let artist: String
        let album: String?
        let durationSeconds: Int
        let isrc: String?
    }

    private struct BiniMatch: Sendable {
        let isrc: String?
        let lyricsURL: String?
    }

    private enum ProviderKind: Hashable, Sendable {
        case lrcRed
        case biniLyrics
        case betterLyrics
        case lyricsPlus
        case lrclib
        case kugou
        case youtubeMusic
        case genius

        var displayName: String {
            switch self {
            case .lrcRed: return "lrc.red"
            case .biniLyrics: return "BiniLyrics"
            case .betterLyrics: return "BetterLyrics"
            case .lyricsPlus: return "LyricsPlus"
            case .lrclib: return "LRCLIB"
            case .kugou: return "KuGou"
            case .youtubeMusic: return "YouTube Music"
            case .genius: return "Genius"
            }
        }

        static func from(_ name: String) -> ProviderKind? {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "lrc.red", "lrcred": return .lrcRed
            case "binilyrics", "bini": return .biniLyrics
            case "betterlyrics", "better": return .betterLyrics
            case "lyricsplus", "lyrics+": return .lyricsPlus
            case "lrclib": return .lrclib
            case "kugou": return .kugou
            case "youtube music", "youtube", "ytmusic": return .youtubeMusic
            case "genius": return .genius
            default: return nil
            }
        }
    }

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 9
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
        self.innerTube = InnerTubeClient()
        self.cache = LyricsCache()
    }

    // MARK: - LyricsServiceProtocol

    public func fetchLyrics(track: Track, providerOrder: [String]) async -> LyricsDocument? {
        let orderNames = providerOrder.isEmpty ? AppSettings.defaultLyricsProviders : providerOrder
        var providers: [ProviderKind] = []
        for name in orderNames {
            if let kind = ProviderKind.from(name), !providers.contains(kind) {
                providers.append(kind)
            }
        }
        guard !providers.isEmpty else { return nil }

        let cacheKey = "\(track.id)::\(providers.map(\.displayName).joined(separator: ","))"
        if let cached = await cache.getLyrics(key: cacheKey) {
            return cached
        }

        let cleanedTitle = LyricsQueryCleaner.cleanTitle(track.title)
        let cleanedArtist = LyricsQueryCleaner.cleanArtist(track.artist)
        let baseQuery = Query(
            trackId: track.id,
            videoId: track.videoId,
            title: cleanedTitle,
            artist: cleanedArtist,
            album: track.album,
            durationSeconds: Int(track.duration.rounded()),
            isrc: nil
        )

        // Optional fast ISRC identification via BiniLyrics (max ~2s) when ISRC-aware providers are enabled.
        let needsISRC = providers.contains(.biniLyrics) || providers.contains(.lrcRed) || providers.contains(.lyricsPlus)
        var biniHit: BiniMatch?
        if needsISRC {
            biniHit = await identifyWithBini(query: baseQuery, timeoutSeconds: 2.0)
        }

        let enrichedQuery = Query(
            trackId: baseQuery.trackId,
            videoId: baseQuery.videoId,
            title: baseQuery.title,
            artist: baseQuery.artist,
            album: baseQuery.album,
            durationSeconds: baseQuery.durationSeconds,
            isrc: biniHit?.isrc
        )

        let primaryProviders = providers.enumerated().filter { $0.element != .genius }
        let geniusEnabled = providers.contains(.genius)

        // Race all non-Genius providers concurrently.
        var candidates: [(priority: Int, doc: LyricsDocument)] = []
        await withTaskGroup(of: (Int, LyricsDocument?).self) { group in
            for (index, provider) in primaryProviders {
                group.addTask { [biniHit] in
                    guard !Task.isCancelled else { return (index, nil) }
                    let doc = await self.fetchFromProvider(provider, query: enrichedQuery, biniHit: biniHit)
                    return (index, doc)
                }
            }
            for await (index, doc) in group {
                if let doc, !doc.lines.isEmpty {
                    candidates.append((index, doc))
                }
            }
        }

        if let best = Self.selectBestDocument(from: candidates) {
            await cache.setLyrics(best, for: cacheKey)
            return best
        }

        // Lazy Genius fallback only when higher-priority providers returned nothing.
        if geniusEnabled, !Task.isCancelled {
            if let geniusDoc = await fetchGenius(query: enrichedQuery), !geniusDoc.lines.isEmpty {
                await cache.setLyrics(geniusDoc, for: cacheKey)
                return geniusDoc
            }
        }

        return nil
    }

    public func translateLyrics(document: LyricsDocument, targetLang: String) async throws -> LyricsDocument {
        let lang = targetLang.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lang.isEmpty else {
            throw BitChordError.translationFailed("Target language is empty.")
        }
        guard !document.lines.isEmpty else { return document }

        let cacheKey = "\(document.trackId)::\(document.provider)::\(lang)::\(document.lines.count)"
        if let cached = await cache.getTranslation(key: cacheKey) {
            return cached
        }

        // Collect indices of non-empty lines to translate while preserving empty/instrumental slots.
        let translatableIndices = document.lines.indices.filter {
            !document.lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !translatableIndices.isEmpty else { return document }

        let batches = Self.buildTranslationBatches(indices: translatableIndices, lines: document.lines)
        var translatedByIndex: [Int: String] = [:]

        for batch in batches {
            try Task.checkCancellation()
            let results = try await translateBatch(lines: batch.texts, targetLang: lang)
            guard results.count == batch.indices.count else {
                throw BitChordError.translationFailed("Translated line count mismatch.")
            }
            for (idx, translated) in zip(batch.indices, results) {
                translatedByIndex[idx] = translated
            }
        }

        var updatedLines = document.lines
        for idx in updatedLines.indices {
            if let translated = translatedByIndex[idx], !translated.isEmpty {
                updatedLines[idx].translatedText = translated
            }
        }

        let updatedDoc = LyricsDocument(
            trackId: document.trackId,
            provider: document.provider,
            isSynced: document.isSynced,
            isWordSynced: document.isWordSynced,
            lines: updatedLines,
            plainText: document.plainText
        )
        await cache.setTranslation(updatedDoc, for: cacheKey)
        return updatedDoc
    }

    // MARK: - Provider Selection & Ranking

    private static func selectBestDocument(from candidates: [(priority: Int, doc: LyricsDocument)]) -> LyricsDocument? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            let lTier = syncTier(lhs.doc)
            let rTier = syncTier(rhs.doc)
            if lTier != rTier { return lTier < rTier }
            // Smaller priority index = higher preference in providerOrder
            return lhs.priority > rhs.priority
        }?.doc
    }

    private static func syncTier(_ doc: LyricsDocument) -> Int {
        if doc.isWordSynced { return 3 }
        if doc.isSynced { return 2 }
        return 1
    }

    private func fetchFromProvider(_ provider: ProviderKind, query: Query, biniHit: BiniMatch?) async -> LyricsDocument? {
        switch provider {
        case .lrcRed:
            return await fetchLrcRed(query: query)
        case .biniLyrics:
            return await fetchBiniLyrics(query: query, prematched: biniHit)
        case .betterLyrics:
            return await fetchBetterLyrics(query: query)
        case .lyricsPlus:
            return await fetchLyricsPlus(query: query)
        case .lrclib:
            return await fetchLRCLIB(query: query)
        case .kugou:
            return await fetchKuGou(query: query)
        case .youtubeMusic:
            return await fetchYouTubeMusic(query: query)
        case .genius:
            return await fetchGenius(query: query)
        }
    }

    // MARK: - 1. lrc.red

    private func fetchLrcRed(query: Query) async -> LyricsDocument? {
        if let isrc = query.isrc, Self.isValidISRC(isrc) {
            let directURL = "https://lrc.red/s/\(isrc.uppercased()).ttml"
            if let ttml = await fetchText(directURL),
               let doc = LyricsParsers.parseTTML(ttml, trackId: query.trackId, provider: ProviderKind.lrcRed.displayName) {
                return doc
            }
        }

        let qStr = "\(query.title) \(query.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard let searchURL = Self.buildURL("https://lrc.red/search.json", queryItems: ["q": qStr]),
              let data = await fetchData(searchURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            return nil
        }

        let targetTitle = LyricsQueryCleaner.coreNormalized(query.title)
        let targetArtist = LyricsQueryCleaner.normalized(query.artist)

        let matching = hits.compactMap { hit -> (isrc: String, diff: Double)? in
            guard let isrc = hit["isrc"] as? String, Self.isValidISRC(isrc),
                  let hitTitle = hit["title"] as? String else {
                return nil
            }
            guard LyricsQueryCleaner.coreNormalized(hitTitle) == targetTitle else { return nil }
            let hitArtist = LyricsQueryCleaner.normalized((hit["artist"] as? String) ?? "")
            if !targetArtist.isEmpty && !hitArtist.isEmpty &&
                !hitArtist.contains(targetArtist) && !targetArtist.contains(hitArtist) {
                return nil
            }
            let hitDur = (hit["duration"] as? NSNumber)?.doubleValue ?? 0
            let diff = (query.durationSeconds > 0 && hitDur > 0) ? abs(hitDur - Double(query.durationSeconds)) : 0
            guard diff <= 4.0 else { return nil }
            return (isrc.uppercased(), diff)
        }.min { $0.diff < $1.diff }

        guard let isrc = matching?.isrc else { return nil }
        let docURL = "https://lrc.red/s/\(isrc).ttml"
        guard let ttml = await fetchText(docURL) else { return nil }
        return LyricsParsers.parseTTML(ttml, trackId: query.trackId, provider: ProviderKind.lrcRed.displayName)
    }

    // MARK: - 2. BiniLyrics

    private func identifyWithBini(query: Query, timeoutSeconds: TimeInterval) async -> BiniMatch? {
        var params: [String: String?] = [
            "track": query.title,
            "artist": query.artist,
            "album": query.album
        ]
        if query.durationSeconds > 0 {
            params["duration"] = String(query.durationSeconds)
        }
        guard let url = Self.buildURL("https://lyrics-api.binimum.org/", queryItems: params) else {
            return nil
        }
        guard let data = await fetchData(url, timeout: timeoutSeconds),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              !results.isEmpty else {
            return nil
        }

        // Prefer word-synced entry, breaking ties by closest duration.
        let chosen = results.max { lhs, rhs in
            let lWord = ((lhs["timing_type"] as? String) ?? "").lowercased() == "word" ? 1 : 0
            let rWord = ((rhs["timing_type"] as? String) ?? "").lowercased() == "word" ? 1 : 0
            if lWord != rWord { return lWord < rWord }
            let lDur = (lhs["duration"] as? NSNumber)?.intValue ?? 0
            let rDur = (rhs["duration"] as? NSNumber)?.intValue ?? 0
            let lDiff = query.durationSeconds > 0 && lDur > 0 ? abs(lDur - query.durationSeconds) : 0
            let rDiff = query.durationSeconds > 0 && rDur > 0 ? abs(rDur - query.durationSeconds) : 0
            return lDiff > rDiff
        } ?? results.first

        guard let chosen else { return nil }
        let isrc = chosen["isrc"] as? String
        let lyricsURL = chosen["lyricsUrl"] as? String
        return BiniMatch(isrc: isrc, lyricsURL: lyricsURL)
    }

    private func fetchBiniLyrics(query: Query, prematched: BiniMatch?) async -> LyricsDocument? {
        let hit: BiniMatch?
        if let prematched {
            hit = prematched
        } else {
            hit = await identifyWithBini(query: query, timeoutSeconds: 6.0)
        }
        guard let lyricsURL = hit?.lyricsURL, !lyricsURL.isEmpty,
              let body = await fetchText(lyricsURL) else {
            return nil
        }
        return LyricsParsers.parseAuto(body, trackId: query.trackId, provider: ProviderKind.biniLyrics.displayName)
    }

    // MARK: - 3. BetterLyrics

    private func fetchBetterLyrics(query: Query) async -> LyricsDocument? {
        var params: [String: String?] = [
            "s": query.title,
            "a": query.artist,
            "al": query.album
        ]
        if query.durationSeconds > 0 {
            params["d"] = String(query.durationSeconds)
        }
        guard let url = Self.buildURL("https://lyrics-api.boidu.dev/getLyrics", queryItems: params),
              let raw = await fetchText(url) else {
            return nil
        }
        return LyricsParsers.parseProviderEnvelope(raw, trackId: query.trackId, provider: ProviderKind.betterLyrics.displayName)
    }

    // MARK: - 4. LyricsPlus (Multi-Mirror Fallback)

    private func fetchLyricsPlus(query: Query) async -> LyricsDocument? {
        var params: [String: String?] = [
            "title": query.title,
            "artist": query.artist,
            "album": query.album,
            "isrc": query.isrc
        ]
        if query.durationSeconds > 0 {
            params["duration"] = String(query.durationSeconds)
        }

        // Race mirrors concurrently; take the first usable parsed document.
        return await withTaskGroup(of: LyricsDocument?.self) { group in
            for mirror in Self.lyricsPlusMirrors {
                group.addTask {
                    guard let url = Self.buildURL("\(mirror)/v2/lyrics/get", queryItems: params),
                          let data = await self.fetchData(url, timeout: 7.0),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }
                    return LyricsParsers.parseLyricsPlus(
                        json,
                        trackId: query.trackId,
                        provider: ProviderKind.lyricsPlus.displayName
                    )
                }
            }
            for await result in group {
                if let doc = result, !doc.lines.isEmpty {
                    group.cancelAll()
                    return doc
                }
            }
            return nil
        }
    }

    // MARK: - 5. LRCLIB

    private func fetchLRCLIB(query: Query) async -> LyricsDocument? {
        let title = LyricsQueryCleaner.cleanLRCLIB(query.title)
        let artist = LyricsQueryCleaner.cleanLRCLIB(query.artist)

        var exactParams: [String: String?] = [
            "track_name": title,
            "artist_name": artist
        ]
        if query.durationSeconds > 0 {
            exactParams["duration"] = String(query.durationSeconds)
        }

        if let url = Self.buildURL("https://lrclib.net/api/get", queryItems: exactParams),
           let data = await fetchData(url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let doc = parseLRCLIBEntry(json, trackId: query.trackId) {
                return doc
            }
        }

        guard let searchURL = Self.buildURL(
            "https://lrclib.net/api/search",
            queryItems: ["track_name": title, "artist_name": artist]
        ),
              let data = await fetchData(searchURL),
              let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !hits.isEmpty else {
            return nil
        }

        let sorted = hits.sorted { lhs, rhs in
            let lSynced = ((lhs["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0
            let rSynced = ((rhs["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0
            if lSynced != rSynced { return lSynced > rSynced }
            let lDur = (lhs["duration"] as? NSNumber)?.doubleValue ?? 0
            let rDur = (rhs["duration"] as? NSNumber)?.doubleValue ?? 0
            let target = Double(query.durationSeconds)
            return abs(lDur - target) < abs(rDur - target)
        }

        for entry in sorted {
            if let doc = parseLRCLIBEntry(entry, trackId: query.trackId) {
                return doc
            }
        }
        return nil
    }

    private func parseLRCLIBEntry(_ json: [String: Any], trackId: String) -> LyricsDocument? {
        if let synced = json["syncedLyrics"] as? String,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let enhanced = LyricsParsers.parseEnhancedLRC(synced, trackId: trackId, provider: ProviderKind.lrclib.displayName) {
                return enhanced
            }
            if let lrc = LyricsParsers.parseStandardLRC(synced, trackId: trackId, provider: ProviderKind.lrclib.displayName) {
                return lrc
            }
        }
        if let plain = json["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsParsers.parsePlain(plain, trackId: trackId, provider: ProviderKind.lrclib.displayName)
        }
        return nil
    }

    // MARK: - 6. KuGou

    private func fetchKuGou(query: Query) async -> LyricsDocument? {
        let cleanTitle = LyricsQueryCleaner.stripParenthetical(query.title)
        let cleanArtist = LyricsQueryCleaner.stripParenthetical(query.artist)
        let keyword = "\(cleanTitle) - \(cleanArtist)\(query.album.map { " \($0)" } ?? "")"

        var candidatePair: (id: String, accesskey: String)?

        // Step 1: Song search -> hashes matching duration
        if let songURL = Self.buildURL(
            "https://mobileservice.kugou.com/api/v3/search/song",
            queryItems: [
                "version": "9108",
                "plat": "0",
                "pagesize": "8",
                "showtype": "0",
                "keyword": keyword
            ]
        ),
           let data = await fetchData(songURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = (json["data"] as? [String: Any])?["info"] as? [[String: Any]] {
            let hashes = info.compactMap { entry -> (hash: String, diff: Int)? in
                guard let hash = entry["hash"] as? String, !hash.isEmpty else { return nil }
                let dur = (entry["duration"] as? NSNumber)?.intValue ?? -1
                if query.durationSeconds > 0 && dur > 0 && abs(dur - query.durationSeconds) > 8 {
                    return nil
                }
                return (hash, query.durationSeconds > 0 && dur > 0 ? abs(dur - query.durationSeconds) : 0)
            }.sorted { $0.diff < $1.diff }.map(\.hash)

            for hash in hashes.prefix(3) {
                if let cand = await searchKuGouCandidate(params: ["ver": "1", "man": "yes", "client": "pc", "hash": hash]) {
                    candidatePair = cand
                    break
                }
            }
        }

        // Fallback keyword search directly on lyrics.kugou.com
        if candidatePair == nil {
            var params: [String: String?] = [
                "ver": "1",
                "man": "yes",
                "client": "pc",
                "keyword": keyword
            ]
            if query.durationSeconds > 0 {
                params["duration"] = String(query.durationSeconds * 1000)
            }
            candidatePair = await searchKuGouCandidate(params: params)
        }

        guard let cand = candidatePair,
              let dlURL = Self.buildURL(
                "https://lyrics.kugou.com/download",
                queryItems: [
                    "fmt": "lrc",
                    "charset": "utf8",
                    "client": "pc",
                    "ver": "1",
                    "id": cand.id,
                    "accesskey": cand.accesskey
                ]
              ),
              let data = await fetchData(dlURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64Content = json["content"] as? String,
              let decodedData = Data(base64Encoded: base64Content),
              let rawLRC = String(data: decodedData, encoding: .utf8) else {
            return nil
        }

        let stripped = LyricsParsers.stripKuGouCredits(rawLRC)
        guard !stripped.isEmpty, !LyricsParsers.isKuGouInstrumentalNotice(stripped) else {
            return nil
        }
        return LyricsParsers.parseStandardLRC(stripped, trackId: query.trackId, provider: ProviderKind.kugou.displayName)
    }

    private func searchKuGouCandidate(params: [String: String?]) async -> (id: String, accesskey: String)? {
        guard let url = Self.buildURL("https://lyrics.kugou.com/search", queryItems: params),
              let data = await fetchData(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let id = first["id"] as? String,
              let accesskey = first["accesskey"] as? String else {
            return nil
        }
        return (id, accesskey)
    }

    // MARK: - 7. YouTube Music (InnerTube /next Lyrics tab + /get_transcript fallback)

    private func fetchYouTubeMusic(query: Query) async -> LyricsDocument? {
        guard query.videoId.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return nil
        }

        if let text = await innerTube.fetchLyricsFromWatchPage(videoId: query.videoId) {
            if let doc = LyricsParsers.parsePlain(text, trackId: query.trackId, provider: ProviderKind.youtubeMusic.displayName) {
                return doc
            }
        }

        if let cues = await innerTube.fetchTranscriptCues(videoId: query.videoId), !cues.isEmpty {
            var lines: [LyricLine] = []
            for (idx, cue) in cues.enumerated() {
                let end = idx + 1 < cues.count ? cues[idx + 1].startTime : cue.startTime + 3.0
                lines.append(LyricLine(startTime: cue.startTime, endTime: max(cue.startTime, end), text: cue.text))
            }
            return LyricsDocument(
                trackId: query.trackId,
                provider: ProviderKind.youtubeMusic.displayName,
                isSynced: true,
                isWordSynced: false,
                lines: lines
            )
        }

        return nil
    }

    // MARK: - 8. Genius (Lazy Fallback)

    private func fetchGenius(query: Query) async -> LyricsDocument? {
        let cleanTitle = LyricsQueryCleaner.cleanGenius(query.title)
        let cleanArtist = LyricsQueryCleaner.cleanGenius(query.artist)
        let bareTitle = LyricsQueryCleaner.stripParenthetical(cleanTitle)
        let attempts = Array(Set([
            "\(cleanArtist) \(cleanTitle)".trimmingCharacters(in: .whitespaces),
            "\(cleanArtist) \(bareTitle)".trimmingCharacters(in: .whitespaces),
            bareTitle.isEmpty ? cleanTitle : bareTitle
        ])).filter { !$0.isEmpty }

        let targetTitle = (bareTitle.isEmpty ? cleanTitle : bareTitle).lowercased()
        let targetArtist = cleanArtist.lowercased()

        for attempt in attempts {
            guard let searchURL = Self.buildURL("https://genius.com/api/search/multi", queryItems: ["q": attempt]),
                  let data = await fetchData(searchURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sections = (json["response"] as? [String: Any])?["sections"] as? [[String: Any]] else {
                continue
            }

            let songHits = sections
                .first { ($0["type"] as? String) == "song" }?["hits"] as? [[String: Any]] ?? []

            let bestURL = songHits.compactMap { wrapper -> (url: String, score: Int)? in
                guard let hit = wrapper["result"] as? [String: Any],
                      let urlStr = hit["url"] as? String else { return nil }
                let ht = ((hit["title"] as? String) ?? "").lowercased()
                let ha = ((hit["artist_names"] as? String) ?? "").lowercased()
                let titleMatch = !targetTitle.isEmpty && (ht == targetTitle || ht.contains(targetTitle) || targetTitle.contains(ht))
                let artistMatch = !targetArtist.isEmpty && (ha == targetArtist || ha.contains(targetArtist) || targetArtist.contains(ha))
                guard titleMatch || artistMatch else { return nil }

                var score = (ht == targetTitle ? 50 : (titleMatch ? 25 : 0))
                    + (artistMatch ? (ha == targetArtist ? 40 : 20) : 0)
                let path = ((hit["path"] as? String) ?? "").lowercased()
                if path.contains("translation") && !targetTitle.contains("translation") { score -= 30 }
                if path.contains("tracklist") || path.contains("album-art") { score -= 50 }
                return score > 0 ? (urlStr, score) : nil
            }.max { $0.score < $1.score }?.url

            guard let pageURL = bestURL, let html = await fetchText(pageURL) else { continue }
            let lines = LyricsParsers.parseGeniusHTML(html)
            if !lines.isEmpty {
                return LyricsDocument(
                    trackId: query.trackId,
                    provider: ProviderKind.genius.displayName,
                    isSynced: false,
                    isWordSynced: false,
                    lines: lines
                )
            }
        }
        return nil
    }

    // MARK: - Google Translate (gtx Batched)

    private struct TranslationBatch {
        let indices: [Int]
        let texts: [String]
    }

    private static func buildTranslationBatches(indices: [Int], lines: [LyricLine]) -> [TranslationBatch] {
        let maxChars = 3_200
        var batches: [TranslationBatch] = []
        var currentIndices: [Int] = []
        var currentTexts: [String] = []
        var currentLength = 0

        for idx in indices {
            let text = lines[idx].text
            let added = text.count + 12
            if !currentIndices.isEmpty && currentLength + added > maxChars {
                batches.append(TranslationBatch(indices: currentIndices, texts: currentTexts))
                currentIndices = []
                currentTexts = []
                currentLength = 0
            }
            currentIndices.append(idx)
            currentTexts.append(text)
            currentLength += added
        }
        if !currentIndices.isEmpty {
            batches.append(TranslationBatch(indices: currentIndices, texts: currentTexts))
        }
        return batches
    }

    private func translateBatch(lines: [String], targetLang: String) async throws -> [String] {
        // Join with private-use marker so Google Translate preserves exact line alignment.
        var payloadParts: [String] = []
        for (i, text) in lines.enumerated() {
            if i > 0 {
                payloadParts.append("\n\u{E000}\(String(format: "%04d", i))\u{E001}\n")
            }
            payloadParts.append(text)
        }
        let joinedPayload = payloadParts.joined()

        guard let url = Self.buildURL(
            "https://translate.googleapis.com/translate_a/single",
            queryItems: [
                "client": "gtx",
                "sl": "auto",
                "tl": targetLang,
                "dt": "t"
            ]
        ) else {
            throw BitChordError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encodedQuery = Self.formURLEncode(joinedPayload)
        request.httpBody = Data("q=\(encodedQuery)".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BitChordError.translationFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BitChordError.translationFailed("Translate endpoint returned HTTP \(code).")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw BitChordError.translationFailed("Unexpected translation response format.")
        }

        var combined = ""
        for seg in segments {
            if let arr = seg as? [Any], let chunk = arr.first as? String {
                combined += chunk
            }
        }

        // Split on marker regex (`\uE000...\uE001`)
        let markerSplit = Self.splitByMarker(combined)
        if markerSplit.count == lines.count {
            return markerSplit
        }

        // Graceful fallback: if Google modified markers, retry with plain newline join once.
        let fallbackLines = combined
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if fallbackLines.count == lines.count {
            return fallbackLines
        }

        throw BitChordError.translationFailed("Could not align translated lines (\(markerSplit.count) vs \(lines.count)).")
    }

    private static func splitByMarker(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\u{E000}[^\u{E001}]*\u{E001}"#) else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        if matches.isEmpty {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        var parts: [String] = []
        var cursor = text.startIndex
        for match in matches {
            if let range = Range(match.range, in: text) {
                parts.append(String(text[cursor..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                cursor = range.upperBound
            }
        }
        parts.append(String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - HTTP & URL Helpers

    private func fetchData(_ url: URL, timeout: TimeInterval? = nil) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let timeout { req.timeoutInterval = timeout }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    private func fetchText(_ urlString: String, timeout: TimeInterval? = nil) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return await fetchText(url, timeout: timeout)
    }

    private func fetchText(_ url: URL, timeout: TimeInterval? = nil) async -> String? {
        guard let data = await fetchData(url, timeout: timeout) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func buildURL(_ base: String, queryItems: [String: String?]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var items: [URLQueryItem] = []
        for (key, value) in queryItems.sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url
    }

    private static func isValidISRC(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .range(of: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Query Cleaning Helpers

private enum LyricsQueryCleaner {
    static func cleanTitle(_ title: String) -> String {
        var s = title
            .replacingOccurrences(
                of: #"\s*[\(\[]\s*(?:official(?:\s+music)?\s+(?:video|audio|lyric\s+video)|lyrics?|visualizer|audio|hd|4k|mv|remastered(?:\s+\d{4})?)\s*[\)\]]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    static func cleanArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(" - Topic") {
            return String(trimmed.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func cleanLRCLIB(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(
                of: #"\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^\]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .components(separatedBy: " | ").first?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    static func cleanGenius(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"[♪♫★☆【】《》「」~_]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\s*[\(\[]\s*(?:from|feat\.?|ft\.?|featuring|with|prod\.?|produced by|official|lyrical|video|audio|remix|music video|visualizer|mv|hd|4k|hq|full song)[^\)\]]*[\)\]]"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .components(separatedBy: " | ").first?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    static func stripParenthetical(_ value: String) -> String {
        let stripped = value
            .replacingOccurrences(of: #"[\(（].*?[\)）]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[.*?\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func coreNormalized(_ title: String) -> String {
        let stripped = title
            .replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
            .components(separatedBy: " - ").first ?? title
        let norm = normalized(stripped)
        return norm.isEmpty ? normalized(title) : norm
    }
}

// MARK: - Lyrics Format Parsers (TTML, Enhanced LRC, Standard LRC, LyricsPlus, Genius, Plain)

internal enum LyricsParsers {
    private static let envelopeContentKeys = [
        "ttml", "ttmlContent", "lyrics", "lrc", "content", "text",
        "syncedLyrics", "plainLyrics", "line", "lines", "lyric", "data", "result", "response"
    ]

    // MARK: - Auto / Provider Envelope

    static func parseProviderEnvelope(_ raw: String, trackId: String, provider: String) -> LyricsDocument? {
        guard let unwrapped = unwrapEnvelope(raw) else { return nil }
        return parseAuto(unwrapped, trackId: trackId, provider: provider)
    }

    static func parseAuto(_ raw: String, trackId: String, provider: String) -> LyricsDocument? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("&lt;tt") ? decodeHTMLEntities(trimmed) : trimmed

        if candidate.contains("<tt") || candidate.contains("<p ") || candidate.contains("<p>") {
            if let ttml = parseTTML(candidate, trackId: trackId, provider: provider) {
                return ttml
            }
        }
        if let enhanced = parseEnhancedLRC(candidate, trackId: trackId, provider: provider) {
            return enhanced
        }
        if let standard = parseStandardLRC(candidate, trackId: trackId, provider: provider) {
            return standard
        }
        return parsePlain(candidate, trackId: trackId, provider: provider)
    }

    private static func unwrapEnvelope(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{"), let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return extractContentString(obj)
        }
        if text.hasPrefix("["), let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) {
            return extractContentString(arr)
        }
        return text
    }

    private static func extractContentString(_ value: Any) -> String? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
               let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data),
               let inner = extractContentString(nested) {
                return inner
            }
            return trimmed
        }
        if let arr = value as? [Any] {
            let joined = arr.compactMap { extractContentString($0) }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        if let dict = value as? [String: Any] {
            if (dict["isError"] as? Bool) == true || (dict["ok"] as? Bool) == false {
                return nil
            }
            if let err = dict["error"] as? String, !err.isEmpty {
                return nil
            }
            for key in envelopeContentKeys {
                if let val = dict[key], let found = extractContentString(val) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - TTML Parser (Foundation.XMLParser)

    static func parseTTML(_ ttml: String, trackId: String, provider: String) -> LyricsDocument? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = TTMLXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        let lines = delegate.finalizeLines()
        guard !lines.isEmpty else { return nil }
        let isWordSynced = lines.contains { $0.isWordSynced }
        return LyricsDocument(
            trackId: trackId,
            provider: provider,
            isSynced: true,
            isWordSynced: isWordSynced,
            lines: lines
        )
    }

    private final class TTMLXMLDelegate: NSObject, XMLParserDelegate {
        private enum Piece {
            case text(String)
            case timed(text: String, start: TimeInterval, end: TimeInterval)
        }

        private struct SpanFrame {
            let role: String
            let begin: TimeInterval?
            let end: TimeInterval?
            var hasTimedChild: Bool = false
            var collectedText: String = ""
        }

        private var inParagraph = false
        private var paragraphBegin: TimeInterval?
        private var paragraphEnd: TimeInterval?
        private var paragraphRawText = ""
        private var mainPieces: [Piece] = []
        private var bgPieces: [Piece] = []
        private var spanStack: [SpanFrame] = []
        private var skipDepth = 0
        private var bgDepth = 0
        private var parsedLines: [LyricLine] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let local = localName(elementName)
            if local == "p" {
                inParagraph = true
                paragraphBegin = Self.parseTTMLTime(attributeDict["begin"])
                paragraphEnd = Self.parseTTMLTime(attributeDict["end"])
                paragraphRawText = ""
                mainPieces = []
                bgPieces = []
                spanStack = []
                skipDepth = 0
                bgDepth = 0
                return
            }

            guard inParagraph else { return }

            if local == "br" {
                if skipDepth == 0 {
                    flushTopSpanBufferedText()
                    appendText(" ")
                }
                return
            }

            if local == "span" {
                let role = attributeValue(attributeDict, localKey: "role").lowercased()
                if role == "x-translation" || role == "x-roman" {
                    skipDepth += 1
                    spanStack.append(SpanFrame(role: role, begin: nil, end: nil))
                    return
                }
                if skipDepth > 0 {
                    skipDepth += 1
                    spanStack.append(SpanFrame(role: role, begin: nil, end: nil))
                    return
                }

                // Flush any text (e.g. inter-word whitespace) buffered on the enclosing span
                // before pushing the child span so pieces stay in exact document order.
                flushTopSpanBufferedText()

                let begin = Self.parseTTMLTime(attributeDict["begin"])
                let end = Self.parseTTMLTime(attributeDict["end"])
                if begin != nil {
                    for i in spanStack.indices {
                        spanStack[i].hasTimedChild = true
                    }
                }
                if role == "x-bg" {
                    bgDepth += 1
                }
                spanStack.append(SpanFrame(role: role, begin: begin, end: end))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inParagraph, skipDepth == 0 else { return }
            if !spanStack.isEmpty {
                spanStack[spanStack.count - 1].collectedText += string
            } else {
                appendText(string)
            }
            if bgDepth == 0 {
                paragraphRawText += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let local = localName(elementName)

            if local == "span", inParagraph, let frame = spanStack.popLast() {
                if skipDepth > 0 {
                    skipDepth -= 1
                    return
                }

                let isBackground = bgDepth > 0
                if !frame.hasTimedChild, let begin = frame.begin, let end = frame.end {
                    let piece = Piece.timed(text: frame.collectedText, start: begin, end: max(begin, end))
                    if isBackground {
                        bgPieces.append(piece)
                    } else {
                        mainPieces.append(piece)
                    }
                } else if !frame.collectedText.isEmpty {
                    let piece = Piece.text(frame.collectedText)
                    if isBackground {
                        bgPieces.append(piece)
                    } else {
                        mainPieces.append(piece)
                    }
                }

                if frame.role == "x-bg" {
                    bgDepth = max(0, bgDepth - 1)
                }
                return
            }

            if local == "p", inParagraph {
                emitParagraph()
                inParagraph = false
            }
        }

        private func flushTopSpanBufferedText() {
            guard !spanStack.isEmpty else { return }
            let buffered = spanStack[spanStack.count - 1].collectedText
            guard !buffered.isEmpty else { return }
            spanStack[spanStack.count - 1].collectedText = ""
            appendText(buffered)
        }

        private func appendText(_ text: String) {
            if bgDepth > 0 {
                bgPieces.append(.text(text))
            } else {
                mainPieces.append(.text(text))
            }
        }

        private func emitParagraph() {
            let mainWords = Self.mergePiecesIntoWords(mainPieces)
            let bgWords = Self.mergePiecesIntoWords(bgPieces)

            if !mainWords.isEmpty {
                let start = min(paragraphBegin ?? mainWords[0].startTime, mainWords[0].startTime)
                let end = max(paragraphEnd ?? mainWords.last!.endTime, mainWords.last!.endTime)
                let text = mainWords.map(\.text).joined(separator: " ")
                parsedLines.append(LyricLine(
                    startTime: start,
                    endTime: end,
                    text: text,
                    words: mainWords,
                    isBackgroundVocal: false
                ))
            } else {
                let text = paragraphRawText
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let begin = paragraphBegin, !text.isEmpty {
                    let end = paragraphEnd ?? (begin + 3.0)
                    parsedLines.append(LyricLine(
                        startTime: begin,
                        endTime: max(begin, end),
                        text: text,
                        words: [],
                        isBackgroundVocal: false
                    ))
                }
            }

            if !bgWords.isEmpty {
                let bgStart = bgWords[0].startTime
                let bgEnd = bgWords.last!.endTime
                let bgText = bgWords.map(\.text).joined(separator: " ")
                parsedLines.append(LyricLine(
                    startTime: bgStart,
                    endTime: max(bgStart, bgEnd),
                    text: bgText,
                    words: bgWords,
                    isBackgroundVocal: true
                ))
            }
        }

        func finalizeLines() -> [LyricLine] {
            var sorted = parsedLines.sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return !lhs.isBackgroundVocal && rhs.isBackgroundVocal
            }
            for i in sorted.indices {
                if sorted[i].endTime <= sorted[i].startTime {
                    let nextStart = i + 1 < sorted.count ? sorted[i + 1].startTime : sorted[i].startTime + 3.0
                    sorted[i].endTime = max(sorted[i].startTime, nextStart)
                }
            }
            return sorted
        }

        /// Merges syllable spans without separating whitespace into word-level `LyricWord`s.
        private static func mergePiecesIntoWords(_ pieces: [Piece]) -> [LyricWord] {
            var words: [LyricWord] = []
            var currentText = ""
            var currentStart: TimeInterval = 0
            var currentEnd: TimeInterval = 0
            var hasTiming = false

            func flush() {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                currentText = ""
                if !trimmed.isEmpty && hasTiming {
                    words.append(LyricWord(
                        startTime: currentStart,
                        endTime: max(currentStart, currentEnd),
                        text: trimmed
                    ))
                }
                hasTiming = false
            }

            for piece in pieces {
                switch piece {
                case .text(let raw):
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flush()
                    } else if hasTiming {
                        currentText += raw
                    }
                case .timed(let raw, let start, let end):
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        flush()
                        continue
                    }
                    let leadingSpace = raw.first?.isWhitespace == true
                    let trailingSpace = raw.last?.isWhitespace == true
                    if leadingSpace { flush() }
                    if currentText.isEmpty {
                        currentStart = start
                    }
                    currentText += trimmed
                    currentEnd = max(currentEnd, end)
                    hasTiming = true
                    if trailingSpace { flush() }
                }
            }
            flush()
            return words
        }

        private func localName(_ elementName: String) -> String {
            if let colon = elementName.lastIndex(of: ":") {
                return String(elementName[elementName.index(after: colon)...]).lowercased()
            }
            return elementName.lowercased()
        }

        private func attributeValue(_ attrs: [String: String], localKey: String) -> String {
            if let direct = attrs[localKey] { return direct }
            for (k, v) in attrs {
                if localName(k) == localKey { return v }
            }
            return ""
        }

        static func parseTTMLTime(_ raw: String?) -> TimeInterval? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            if trimmed.hasSuffix("ms") {
                if let ms = Double(trimmed.dropLast(2)) { return ms / 1000.0 }
                return nil
            }
            let cleaned = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
            let parts = cleaned.split(separator: ":").compactMap { Double($0) }
            guard !parts.isEmpty, parts.count <= 3 else { return nil }
            return parts.reduce(0.0) { $0 * 60.0 + $1 }
        }
    }

    // MARK: - LyricsPlus JSON Parser

    static func parseLyricsPlus(_ json: [String: Any], trackId: String, provider: String) -> LyricsDocument? {
        guard let entries = json["lyrics"] as? [[String: Any]], !entries.isEmpty else {
            return nil
        }

        var lines: [LyricLine] = []
        for entry in entries {
            guard let timeMs = (entry["time"] as? NSNumber)?.doubleValue else { continue }
            let durationMs = (entry["duration"] as? NSNumber)?.doubleValue ?? 0
            let lineStart = timeMs / 1000.0
            let lineEnd = durationMs > 0 ? (timeMs + durationMs) / 1000.0 : lineStart

            var words: [LyricWord] = []
            if let syllabus = entry["syllabus"] as? [[String: Any]], !syllabus.isEmpty {
                var currentWord = ""
                var wordStart: TimeInterval = 0
                var wordEnd: TimeInterval = 0

                func flushWord() {
                    let trimmed = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentWord = ""
                    if !trimmed.isEmpty {
                        words.append(LyricWord(startTime: wordStart, endTime: max(wordStart, wordEnd), text: trimmed))
                    }
                }

                for syl in syllabus {
                    guard let rawText = syl["text"] as? String,
                          let sylTime = (syl["time"] as? NSNumber)?.doubleValue else { continue }
                    let sylDur = (syl["duration"] as? NSNumber)?.doubleValue ?? 0
                    let sStart = sylTime / 1000.0
                    let sEnd = (sylTime + sylDur) / 1000.0
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        flushWord()
                        continue
                    }
                    if rawText.first?.isWhitespace == true { flushWord() }
                    if currentWord.isEmpty { wordStart = sStart }
                    currentWord += trimmed
                    wordEnd = max(wordEnd, sEnd)
                    if rawText.last?.isWhitespace == true { flushWord() }
                }
                flushWord()
            }

            let isBackground: Bool = {
                if let elem = entry["element"] as? [String: Any] {
                    return (elem["isBackground"] as? Bool) == true
                }
                return false
            }()

            if !words.isEmpty {
                let text = words.map(\.text).joined(separator: " ")
                let start = min(lineStart, words[0].startTime)
                let end = max(lineEnd, words.last!.endTime)
                lines.append(LyricLine(startTime: start, endTime: end, text: text, words: words, isBackgroundVocal: isBackground))
            } else if let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty {
                lines.append(LyricLine(startTime: lineStart, endTime: lineEnd, text: text, words: [], isBackgroundVocal: isBackground))
            }
        }

        lines.sort { $0.startTime < $1.startTime }
        for i in lines.indices where lines[i].endTime <= lines[i].startTime {
            let nextStart = i + 1 < lines.count ? lines[i + 1].startTime : lines[i].startTime + 3.0
            lines[i].endTime = max(lines[i].startTime, nextStart)
        }

        guard !lines.isEmpty else { return nil }
        return LyricsDocument(
            trackId: trackId,
            provider: provider,
            isSynced: true,
            isWordSynced: lines.contains { $0.isWordSynced },
            lines: lines
        )
    }

    // MARK: - Enhanced LRC Parser (`[mm:ss.xx]<mm:ss.xx>word`)

    static func parseEnhancedLRC(_ lrc: String, trackId: String, provider: String) -> LyricsDocument? {
        guard let lineRegex = try? NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$"#),
              let wordRegex = try? NSRegularExpression(pattern: #"<(\d{1,3}):(\d{2})[.:](\d{2,3})>([^<]*)"#) else {
            return nil
        }

        let offsetSec = parseLRCOffsetSeconds(lrc)
        struct RawRow {
            let start: TimeInterval
            let wordMatches: [(TimeInterval, String)]
            let plain: String
        }

        var rows: [RawRow] = []
        var anyWordTimed = false

        for rawLine in lrc.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            guard let m = lineRegex.firstMatch(in: trimmed, range: nsRange),
                  let m1 = Range(m.range(at: 1), in: trimmed),
                  let m2 = Range(m.range(at: 2), in: trimmed),
                  let m3 = Range(m.range(at: 3), in: trimmed),
                  let m4 = Range(m.range(at: 4), in: trimmed) else {
                continue
            }

            let lineTime = max(0, lrcTimestamp(String(trimmed[m1]), String(trimmed[m2]), String(trimmed[m3])) + offsetSec)
            let body = String(trimmed[m4])
            let bodyRange = NSRange(body.startIndex..., in: body)
            let wMatches = wordRegex.matches(in: body, range: bodyRange)

            var words: [(TimeInterval, String)] = []
            for wm in wMatches {
                if let w1 = Range(wm.range(at: 1), in: body),
                   let w2 = Range(wm.range(at: 2), in: body),
                   let w3 = Range(wm.range(at: 3), in: body),
                   let w4 = Range(wm.range(at: 4), in: body) {
                    let wt = max(0, lrcTimestamp(String(body[w1]), String(body[w2]), String(body[w3])) + offsetSec)
                    let text = decodeHTMLEntities(String(body[w4]))
                    words.append((wt, text))
                }
            }
            if !words.isEmpty { anyWordTimed = true }
            rows.append(RawRow(start: lineTime, wordMatches: words, plain: decodeHTMLEntities(body).trimmingCharacters(in: .whitespaces)))
        }

        guard anyWordTimed, !rows.isEmpty else { return nil }
        rows.sort { $0.start < $1.start }

        var lines: [LyricLine] = []
        for (idx, row) in rows.enumerated() {
            let nextLineStart = idx + 1 < rows.count ? rows[idx + 1].start : (row.wordMatches.last?.0 ?? row.start) + 0.8
            if row.wordMatches.isEmpty {
                if !row.plain.isEmpty {
                    lines.append(LyricLine(startTime: row.start, endTime: max(row.start, nextLineStart), text: row.plain))
                }
                continue
            }

            var words: [LyricWord] = []
            for (wi, (wt, rawText)) in row.wordMatches.enumerated() {
                let token = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                let wEnd = wi + 1 < row.wordMatches.count ? row.wordMatches[wi + 1].0 : nextLineStart
                words.append(LyricWord(startTime: wt, endTime: max(wt, wEnd), text: token))
            }
            guard !words.isEmpty else { continue }
            let start = min(row.start, words[0].startTime)
            let end = max(nextLineStart, words.last!.endTime)
            lines.append(LyricLine(
                startTime: start,
                endTime: end,
                text: words.map(\.text).joined(separator: " "),
                words: words
            ))
        }

        guard !lines.isEmpty else { return nil }
        return LyricsDocument(
            trackId: trackId,
            provider: provider,
            isSynced: true,
            isWordSynced: true,
            lines: lines
        )
    }

    // MARK: - Standard LRC Parser (`[mm:ss.xx]`)

    static func parseStandardLRC(_ lrc: String, trackId: String, provider: String) -> LyricsDocument? {
        guard let stampRegex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#) else {
            return nil
        }

        let offsetSec = parseLRCOffsetSeconds(lrc)
        var parsed: [LyricLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let nsRange = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = stampRegex.matches(in: rawLine, range: nsRange)
            guard !matches.isEmpty else { continue }

            // Collect all leading timestamps (handles `[00:12.00][00:45.00]Chorus`).
            var timestamps: [TimeInterval] = []
            var lastEndIndex = rawLine.startIndex
            for match in matches {
                guard let fullRange = Range(match.range, in: rawLine),
                      let m1 = Range(match.range(at: 1), in: rawLine),
                      let m2 = Range(match.range(at: 2), in: rawLine) else { continue }
                let frac: String
                if match.range(at: 3).location != NSNotFound, let m3 = Range(match.range(at: 3), in: rawLine) {
                    frac = String(rawLine[m3])
                } else {
                    frac = "00"
                }
                timestamps.append(max(0, lrcTimestamp(String(rawLine[m1]), String(rawLine[m2]), frac) + offsetSec))
                lastEndIndex = fullRange.upperBound
            }

            var body = String(rawLine[lastEndIndex...])
                .replacingOccurrences(of: #"<\d{1,3}:\d{2}[.:]\d{1,3}>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("<R>") {
                body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            body = decodeHTMLEntities(body)
            guard !body.isEmpty else { continue }

            for ts in timestamps {
                parsed.append(LyricLine(startTime: ts, endTime: ts, text: body))
            }
        }

        parsed.sort { $0.startTime < $1.startTime }
        for i in parsed.indices {
            let nextStart = i + 1 < parsed.count ? parsed[i + 1].startTime : parsed[i].startTime + 4.0
            parsed[i].endTime = max(parsed[i].startTime, nextStart)
        }

        guard !parsed.isEmpty else { return nil }
        return LyricsDocument(
            trackId: trackId,
            provider: provider,
            isSynced: true,
            isWordSynced: false,
            lines: parsed
        )
    }

    // MARK: - Plain Lyrics Parser

    static func parsePlain(_ text: String, trackId: String, provider: String) -> LyricsDocument? {
        let lower = text.lowercased()
        if lower.contains("lyrics not found") || lower.contains("lyrics unavailable") {
            return nil
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // Exclude LRC metadata tags like `[ar:Artist]`
                return line.range(of: #"^\[[A-Za-z]+:.*\]$"#, options: .regularExpression) == nil
            }
            .map { LyricLine(startTime: 0, endTime: 0, text: $0) }

        guard !lines.isEmpty else { return nil }
        return LyricsDocument(
            trackId: trackId,
            provider: provider,
            isSynced: false,
            isWordSynced: false,
            lines: lines
        )
    }

    // MARK: - KuGou Cleaning

    static func stripKuGouCredits(_ lrc: String) -> String {
        let stampedPattern = #"^\[\d{2}:\d{2}\.\d{2,3}\].*"#
        let creditPattern = #".+\][^[]+[:：].+"#
        let lines = lrc.components(separatedBy: .newlines).filter {
            $0.range(of: stampedPattern, options: .regularExpression) != nil
        }
        guard !lines.isEmpty else { return "" }

        var head = 0
        for i in stride(from: min(25, lines.count - 1), through: 0, by: -1) {
            if lines[i].range(of: creditPattern, options: .regularExpression) != nil {
                head = i + 1
                break
            }
        }
        let body = Array(lines.dropFirst(head))
        var tail = 0
        for i in 0..<min(25, body.count) {
            if body[body.count - 1 - i].range(of: creditPattern, options: .regularExpression) != nil {
                tail = i + 1
                break
            }
        }
        return body.dropLast(tail).joined(separator: "\n")
    }

    static func isKuGouInstrumentalNotice(_ lrc: String) -> Bool {
        let texts = lrc.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\[\d{2}:\d{2}\.\d{2,3}\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return false }
        return texts.allSatisfy { $0.range(of: #"纯音乐.*欣赏"#, options: .regularExpression) != nil }
    }

    // MARK: - Genius HTML Parser

    static func parseGeniusHTML(_ html: String) -> [LyricLine] {
        // Extract all `<div ... data-lyrics-container="true" ...>...</div>` blocks
        let pattern = #"<div[^>]*data-lyrics-container="true"[^>]*>([\s\S]*?)</div>"#
        var chunks: [String] = []
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: nsRange) {
                if let range = Range(match.range(at: 1), in: html) {
                    chunks.append(String(html[range]))
                }
            }
        }

        guard !chunks.isEmpty else { return [] }

        var combined = chunks.joined(separator: "\n")
        // Remove embedded header/ad/script blocks if any
        combined = combined.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
        combined = combined.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
        combined = combined.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        combined = combined.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        combined = decodeHTMLEntities(combined)
        combined = combined.replacingOccurrences(of: #"\d*You might also like"#, with: "", options: [.regularExpression, .caseInsensitive])
        combined = combined.replacingOccurrences(of: #"\d*Embed\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])

        var lines: [LyricLine] = []
        for raw in combined.components(separatedBy: .newlines) {
            let trimmed = raw
                .replacingOccurrences(of: #"\d*Embed\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(LyricLine(startTime: 0, endTime: 0, text: trimmed))
            }
        }
        return lines
    }

    // MARK: - Timestamp & Entity Utilities

    private static func parseLRCOffsetSeconds(_ lrc: String) -> TimeInterval {
        guard let regex = try? NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: lrc, range: NSRange(lrc.startIndex..., in: lrc)),
              let range = Range(match.range(at: 1), in: lrc),
              let ms = Double(lrc[range]) else {
            return 0
        }
        return ms / 1000.0
    }

    private static func lrcTimestamp(_ minStr: String, _ secStr: String, _ fracStr: String) -> TimeInterval {
        let minutes = Double(minStr) ?? 0
        let seconds = Double(secStr) ?? 0
        let fracVal = Double(fracStr) ?? 0
        let fractionSeconds: Double
        switch fracStr.count {
        case 1: fractionSeconds = fracVal / 10.0
        case 2: fractionSeconds = fracVal / 100.0
        default: fractionSeconds = fracVal / 1000.0
        }
        return minutes * 60.0 + seconds + fractionSeconds
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        if let hexRegex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let matches = hexRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                if let full = Range(match.range, in: result),
                   let codeRange = Range(match.range(at: 1), in: result),
                   let value = UInt32(result[codeRange], radix: 16),
                   let scalar = UnicodeScalar(value) {
                    result.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        if let decRegex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let matches = decRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                if let full = Range(match.range, in: result),
                   let codeRange = Range(match.range(at: 1), in: result),
                   let value = UInt32(result[codeRange]),
                   let scalar = UnicodeScalar(value) {
                    result.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        return result
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
