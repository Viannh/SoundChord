import Darwin
import Foundation
import MediaPlayer
import Testing
@testable import SoundChord

// MARK: - Test Helpers

private enum TestFixtures {
    static let fixturesRoot = URL(fileURLWithPath: "/Users/viann/Documents/Music/.upstream/BitChord/web/fixtures")

    static func loadJSON(_ relativePath: String) throws -> [String: Any]? {
        let url = fixturesRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func loadString(_ relativePath: String) throws -> String? {
        let url = fixturesRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private func makeSampleTrack(
    id: String,
    title: String = "Let Down",
    artist: String = "Radiohead",
    artistId: String? = "UCartist1",
    album: String? = "OK Computer",
    albumId: String? = "MPREb_album1",
    duration: TimeInterval = 299,
    artworkURL: URL? = URL(string: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj")
) -> Track {
    Track(
        id: id,
        videoId: id,
        title: title,
        artist: artist,
        artistId: artistId,
        album: album,
        albumId: albumId,
        duration: duration,
        artworkURL: artworkURL
    )
}

private final class StubStreamResolver: StreamResolverProtocol, @unchecked Sendable {
    var resolveCount = 0
    var shouldThrow = false

    func resolveStream(videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        resolveCount += 1
        if shouldThrow {
            throw BitChordError.streamUnavailable("Stub error")
        }
        return ResolvedStream(
            url: URL(string: "https://example.invalid/audio/\(videoId).m4a")!,
            mimeType: "audio/mp4",
            codec: "AAC",
            bitrateKbps: min(256, quality.maxBitrateKbps),
            sampleRateHz: 44100,
            bitDepth: 16,
            clientName: "IOS",
            qualityLabel: "High"
        )
    }

    func clearCache() async {}
}

// MARK: - 1. InnerTubeClient Parsing Tests

@Suite("InnerTubeClient Parsing")
struct InnerTubeClientParsingTests {

    @Test("Real upstream fixtures: Home, Explore, Search, Suggestions, Album, Artist, Playlist, Radio")
    func testRealUpstreamFixtures() throws {
        if let homeJSON = try TestFixtures.loadJSON("innertube/browse-home.json") {
            let shelves = InnerTubeParser.parseShelves(from: homeJSON)
            #expect(!shelves.isEmpty)
            #expect(shelves.allSatisfy { !$0.items.isEmpty })
        }

        if let exploreJSON = try TestFixtures.loadJSON("innertube/browse-explore.json") {
            let shelves = InnerTubeParser.parseShelves(from: exploreJSON)
            let grids = InnerTubeParser.parseNavigationGridShelves(from: exploreJSON)
            #expect(!(shelves.isEmpty && grids.isEmpty))
        }

        if let searchJSON = try TestFixtures.loadJSON("innertube/search-all.json") {
            let results = InnerTubeParser.parseSearchResults(query: "radiohead", from: searchJSON)
            #expect(!results.isEmpty)
            #expect(!results.songs.isEmpty || !results.albums.isEmpty || !results.artists.isEmpty)
        }

        if let suggJSON = try TestFixtures.loadJSON("innertube/search-suggestions.json") {
            let suggestions = InnerTubeParser.parseSearchSuggestions(from: suggJSON)
            #expect(!suggestions.isEmpty)
            #expect(suggestions.allSatisfy { !$0.text.isEmpty })
        }

        if let albumJSON = try TestFixtures.loadJSON("innertube/browse-album.json") {
            let album = InnerTubeParser.parseAlbum(browseId: "MPREb_test", from: albumJSON)
            #expect(!album.title.isEmpty)
            #expect(!album.tracks.isEmpty)
            #expect(album.tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
        }

        if let artistJSON = try TestFixtures.loadJSON("innertube/browse-artist.json") {
            let artist = InnerTubeParser.parseArtist(browseId: "UC_test", from: artistJSON)
            #expect(!artist.name.isEmpty)
            #expect(!artist.topSongs.isEmpty || !artist.albums.isEmpty || !artist.singles.isEmpty)
        }

        if let playlistJSON = try TestFixtures.loadJSON("innertube/browse-playlist.json") {
            let playlist = InnerTubeParser.parsePlaylist(browseId: "VLPL_test", from: playlistJSON)
            #expect(!playlist.title.isEmpty)
            #expect(!playlist.tracks.isEmpty)
        }

        if let radioJSON = try TestFixtures.loadJSON("innertube/next-radio.json") {
            let queue = InnerTubeParser.parseWatchQueue(from: radioJSON)
            #expect(!queue.isEmpty)
            #expect(queue.allSatisfy { !$0.videoId.isEmpty })
        }
    }

    @Test("Synthetic carousel shelf & responsive song row parsing")
    func testSyntheticShelfAndSearchParsing() {
        let syntheticHome: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": ["runs": [["text": "Quick picks"]]]
                                                ]
                                            ],
                                            "contents": [
                                                [
                                                    "musicResponsiveListItemRenderer": [
                                                        "thumbnail": [
                                                            "musicThumbnailRenderer": [
                                                                "thumbnail": [
                                                                    "thumbnails": [[
                                                                        "url": "https://lh3.googleusercontent.com/thumb1=w60-h60-l90-rj",
                                                                        "width": 60,
                                                                        "height": 60
                                                                    ]]
                                                                ]
                                                            ]
                                                        ],
                                                        "flexColumns": [
                                                            [
                                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                                    "text": [
                                                                        "runs": [[
                                                                            "text": "Paranoid Android",
                                                                            "navigationEndpoint": [
                                                                                "watchEndpoint": ["videoId": "fHiGbolFFGw"]
                                                                            ]
                                                                        ]]
                                                                    ]
                                                                ]
                                                            ],
                                                            [
                                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                                    "text": [
                                                                        "runs": [
                                                                            [
                                                                                "text": "Radiohead",
                                                                                "navigationEndpoint": [
                                                                                    "browseEndpoint": ["browseId": "UCq19-LqvG35A-30oyAiPiqA"]
                                                                                ]
                                                                            ],
                                                                            ["text": " • "],
                                                                            [
                                                                                "text": "OK Computer",
                                                                                "navigationEndpoint": [
                                                                                    "browseEndpoint": ["browseId": "MPREb_okc"]
                                                                                ]
                                                                            ],
                                                                            ["text": " • "],
                                                                            ["text": "6:23"]
                                                                        ]
                                                                    ]
                                                                ]
                                                            ]
                                                        ],
                                                        "badges": [[
                                                            "musicInlineBadgeRenderer": [
                                                                "icon": ["iconType": "MUSIC_EXPLICIT_BADGE"]
                                                            ]
                                                        ]]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]

        let shelves = InnerTubeParser.parseShelves(from: syntheticHome)
        #expect(shelves.count == 1)
        #expect(shelves[0].title == "Quick picks")
        #expect(shelves[0].items.count == 1)

        if case .track(let track) = shelves[0].items[0] {
            #expect(track.videoId == "fHiGbolFFGw")
            #expect(track.title == "Paranoid Android")
            #expect(track.artist == "Radiohead")
            #expect(track.artistId == "UCq19-LqvG35A-30oyAiPiqA")
            #expect(track.album == "OK Computer")
            #expect(track.albumId == "MPREb_okc")
            #expect(track.duration == 383)
            #expect(track.isExplicit == true)
            #expect(track.artworkURL?.absoluteString.contains("=w544-h544") == true)
        } else {
            Issue.record("Expected track shelf item")
        }
    }

    @Test("SAPISID cookie extraction and SAPISIDHASH SHA-1 signing")
    func testSAPISIDAuthSigning() {
        let cookie = "PREF=tz=UTC; SAPISID=abc123XYZ/def; SID=xyz"
        #expect(InnerTubeClient.extractSAPISID(from: cookie) == "abc123XYZ/def")

        let fallbackCookie = "__Secure-3PAPISID=fallback_sapisid_val; HSID=1"
        #expect(InnerTubeClient.extractSAPISID(from: fallbackCookie) == "fallback_sapisid_val")

        let header = InnerTubeClient.sapisidHashHeader(
            sapisid: "test_sapisid",
            origin: "https://music.youtube.com",
            timestamp: 1_700_000_000
        )
        #expect(header.hasPrefix("SAPISIDHASH 1700000000_"))
        let digestPart = header.replacingOccurrences(of: "SAPISIDHASH 1700000000_", with: "")
        #expect(digestPart.count == 40) // 160-bit SHA1 hex
        #expect(digestPart.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - 2. LyricsEngine Parsing Tests

@Suite("LyricsEngine Parsing")
struct LyricsEngineParsingTests {

    @Test("TTML word-synced parsing with syllable merging and background vocals (real fixtures + synthetic)")
    func testTTMLWordSyncAndBackgroundVocals() throws {
        // Real upstream lrc.red syllable-synced TTML fixture
        if let ttml = try TestFixtures.loadString("lyrics/lrc-red-document.ttml") {
            let doc = try #require(LyricsParsers.parseTTML(ttml, trackId: "t1", provider: "lrc.red"))
            #expect(doc.isSynced)
            #expect(doc.isWordSynced)
            #expect(doc.lines.count >= 30)
            // First line merges "Trans" + "port" into "Transport"
            #expect(doc.lines[0].text == "Transport")
            #expect(doc.lines[0].words.count == 1)
            #expect(doc.lines[0].words[0].text == "Transport")
            #expect(abs(doc.lines[0].startTime - 22.242) < 0.01)
        }

        // Real upstream BetterLyrics fixture with ttm:role="x-bg" background vocals
        if let betterRaw = try TestFixtures.loadString("lyrics/betterlyrics.json") {
            let doc = try #require(LyricsParsers.parseProviderEnvelope(betterRaw, trackId: "t2", provider: "BetterLyrics"))
            #expect(doc.isSynced)
            #expect(doc.isWordSynced)
            let bgLines = doc.lines.filter(\.isBackgroundVocal)
            #expect(bgLines.count >= 3)
            #expect(bgLines.contains { $0.text.contains("You know where you are") })
        }

        // Synthetic TTML verifying syllable merging, x-bg extraction, and x-translation omission
        let syntheticTTML = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="0:10.000" end="0:14.000">
                <span begin="0:10.000" end="0:10.500">Che</span><span begin="0:10.500" end="0:11.200">mi</span><span begin="0:11.200" end="0:12.000">cal</span>
                <span begin="0:12.100" end="0:13.500">reaction</span>
                <span ttm:role="x-bg">
                  <span begin="0:12.500" end="0:13.000">(oh</span>
                  <span begin="0:13.000" end="0:13.900">yeah)</span>
                </span>
                <span ttm:role="x-translation">reacción química</span>
              </p>
            </div>
          </body>
        </tt>
        """
        let doc = try #require(LyricsParsers.parseTTML(syntheticTTML, trackId: "syn", provider: "TTMLTest"))
        #expect(doc.isSynced)
        #expect(doc.isWordSynced)
        #expect(doc.lines.count == 2)

        let mainLine = try #require(doc.lines.first { !$0.isBackgroundVocal })
        #expect(mainLine.text == "Chemical reaction")
        #expect(!mainLine.text.contains("reacción"))
        #expect(mainLine.words.map(\.text) == ["Chemical", "reaction"])
        #expect(abs(mainLine.words[0].startTime - 10.0) < 0.01)
        #expect(abs(mainLine.words[0].endTime - 12.0) < 0.01)

        let bgLine = try #require(doc.lines.first { $0.isBackgroundVocal })
        #expect(bgLine.isBackgroundVocal)
        #expect(bgLine.text == "(oh yeah)")
        #expect(bgLine.words.count == 2)
    }

    @Test("Enhanced LRC word-synced parsing")
    func testEnhancedLRCParsing() throws {
        let enhanced = """
        [ar:Radiohead]
        [ti:Let Down]
        [offset:250]
        [00:10.00]<00:10.00>One <00:10.80>day <00:11.50>I <00:12.00>am <00:12.60>gonna <00:13.40>grow <00:14.20>wings
        [00:16.00]<00:16.00>A <00:16.40>chemical <00:17.50>reaction
        """
        let doc = try #require(LyricsParsers.parseEnhancedLRC(enhanced, trackId: "elrc", provider: "Enhanced"))
        #expect(doc.isSynced)
        #expect(doc.isWordSynced)
        #expect(doc.lines.count == 2)
        #expect(doc.lines[0].text == "One day I am gonna grow wings")
        #expect(doc.lines[0].words.count == 7)
        // [offset:250] shifts timestamps by +0.25s (or -0.25s depending on LRC sign convention; verify consistent shift)
        let firstWord = doc.lines[0].words[0]
        let secondWord = doc.lines[0].words[1]
        #expect(firstWord.text == "One")
        #expect(secondWord.text == "day")
        #expect(secondWord.startTime > firstWord.startTime)
        #expect(abs((secondWord.startTime - firstWord.startTime) - 0.80) < 0.02)
    }

    @Test("Standard LRC parsing with multi-stamp repeats, offset, and LRCLIB/KuGou fixtures")
    func testStandardLRCParsing() throws {
        let standard = """
        [ti:Chorus Test]
        [offset:500]
        [00:10.00][01:05.50]Repeated chorus line
        [00:25.25]Middle verse line
        """
        let doc = try #require(LyricsParsers.parseStandardLRC(standard, trackId: "lrc", provider: "LRCLIB"))
        #expect(doc.isSynced)
        #expect(!doc.isWordSynced)
        #expect(doc.lines.count == 3)
        // Sorted chronologically: 10.0, 25.25, 65.50 (all shifted by offset)
        #expect(doc.lines[0].text == "Repeated chorus line")
        #expect(doc.lines[1].text == "Middle verse line")
        #expect(doc.lines[2].text == "Repeated chorus line")
        #expect(doc.lines[0].startTime < doc.lines[1].startTime)
        #expect(doc.lines[1].startTime < doc.lines[2].startTime)

        // Real LRCLIB fixture
        if let lrclibJSON = try TestFixtures.loadJSON("lyrics/lrclib-get.json"),
           let synced = lrclibJSON["syncedLyrics"] as? String {
            let lrcDoc = try #require(LyricsParsers.parseStandardLRC(synced, trackId: "lrclib", provider: "LRCLIB"))
            #expect(lrcDoc.isSynced)
            #expect(lrcDoc.lines.count >= 30)
            #expect(lrcDoc.lines[0].text == "Transport")
        }

        // Real LyricsPlus fixture
        if let lpJSON = try TestFixtures.loadJSON("lyrics/lyricsplus-lyricsplus.prjktla.my.id.json") {
            let lpDoc = try #require(LyricsParsers.parseLyricsPlus(lpJSON, trackId: "lp", provider: "LyricsPlus"))
            #expect(lpDoc.isSynced)
            #expect(lpDoc.isWordSynced)
            #expect(!lpDoc.lines.isEmpty)
        }

        // Real KuGou base64 LRC fixture + credit stripping
        if let kugouJSON = try TestFixtures.loadJSON("lyrics/kugou-download.json"),
           let b64 = kugouJSON["content"] as? String,
           let rawData = Data(base64Encoded: b64),
           let decoded = String(data: rawData, encoding: .utf8) {
            let cleaned = LyricsParsers.stripKuGouCredits(decoded)
            #expect(!LyricsParsers.isKuGouInstrumentalNotice(cleaned))
            let kgDoc = try #require(LyricsParsers.parseStandardLRC(cleaned, trackId: "kg", provider: "KuGou"))
            #expect(kgDoc.isSynced)
            #expect(kgDoc.lines.count >= 25)
        }
    }
}

// MARK: - 3. LibraryStore SQLite Persistence Tests

@Suite("LibraryStore SQLite Persistence")
@MainActor
struct LibraryStorePersistenceTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Likes, Playlists CRUD, History, ReplaySummary, Search History, and SQLite reload")
    func testSQLiteCRUDAndReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t1 = makeSampleTrack(id: "vid1", title: "Let Down", artist: "Radiohead", artistId: "art1", album: "OK Computer", albumId: "alb1", duration: 299)
        let t2 = makeSampleTrack(id: "vid2", title: "Paranoid Android", artist: "Radiohead", artistId: "art1", album: "OK Computer", albumId: "alb1", duration: 383)
        let t3 = makeSampleTrack(id: "vid3", title: "Starlight", artist: "Muse", artistId: "art2", album: "Black Holes", albumId: "alb2", duration: 240)

        do {
            let store = LibraryStore(baseDirectory: dir)

            // Likes
            #expect(!store.isLiked(t1.id))
            store.toggleLike(t1)
            store.toggleLike(t2)
            #expect(store.isLiked(t1.id))
            #expect(store.likedTracks.count == 2)
            store.toggleLike(t1)
            #expect(!store.isLiked(t1.id))
            #expect(store.likedTracks.map(\.id) == [t2.id])

            // Playlists CRUD
            let pl = store.createPlaylist(title: "Late Night", description: "Chill vibes")
            #expect(store.playlists.count == 1)
            store.renamePlaylist(id: pl.id, title: "Midnight Coding")
            store.addToPlaylist(playlistId: pl.id, track: t1)
            store.addToPlaylist(playlistId: pl.id, track: t2)
            store.addToPlaylist(playlistId: pl.id, track: t1) // duplicate ignored
            store.addToPlaylist(playlistId: pl.id, track: t3)
            #expect(store.playlists.first(where: { $0.id == pl.id })?.tracks.map(\.id) == ["vid1", "vid2", "vid3"])

            store.reorderPlaylistTracks(playlistId: pl.id, from: IndexSet(integer: 2), to: 0)
            #expect(store.playlists.first(where: { $0.id == pl.id })?.tracks.map(\.id) == ["vid3", "vid1", "vid2"])

            store.removeFromPlaylist(playlistId: pl.id, trackId: t2.id)
            #expect(store.playlists.first(where: { $0.id == pl.id })?.tracks.map(\.id) == ["vid3", "vid1"])

            let doomed = store.createPlaylist(title: "Temp")
            store.deletePlaylist(id: doomed.id)
            #expect(store.playlists.count == 1)

            // History & ReplaySummary
            store.recordPlay(track: t1, durationPlayed: 299)
            store.recordPlay(track: t1, durationPlayed: 299)
            store.recordPlay(track: t2, durationPlayed: 383)
            store.recordPlay(track: t3, durationPlayed: 240)

            let summary = store.computeReplaySummary()
            #expect(summary.totalPlays == 4)
            #expect(summary.uniqueTracksCount == 3)
            #expect(summary.uniqueArtistsCount == 2)
            #expect(summary.totalMinutes == Int(((299.0 + 299.0 + 383.0 + 240.0) / 60.0).rounded()))
            #expect(summary.topTracks.first?.track.id == "vid1")
            #expect(summary.topTracks.first?.playCount == 2)
            #expect(summary.topArtists.first?.name == "Radiohead")
            #expect(summary.topAlbums.first?.title == "OK Computer")
            #expect(summary.longestStreakDays >= 1)
            #expect(summary.peakListeningHour != nil)
            #expect(!summary.monthlyMinutes.isEmpty)

            // Search history & settings
            store.addSearchHistory("Radiohead")
            store.addSearchHistory("Muse")
            store.addSearchHistory("radiohead") // dedupes case-insensitively and moves to front
            #expect(store.searchHistory == ["radiohead", "Muse"])

            var updatedSettings = store.settings
            updatedSettings.crossfadeSeconds = 6
            updatedSettings.eqEnabled = true
            updatedSettings.eqPreset = .bassBoost
            updatedSettings.eqGains = EQPreset.bassBoost.gains
            updatedSettings.streamQuality = .lossless
            store.saveSettings(updatedSettings)
        }

        // Reload from SQLite in a brand new LibraryStore instance
        let reloaded = LibraryStore(baseDirectory: dir)
        #expect(reloaded.isLiked(t2.id))
        #expect(!reloaded.isLiked(t1.id))
        #expect(reloaded.playlists.count == 1)
        #expect(reloaded.playlists[0].title == "Midnight Coding")
        #expect(reloaded.playlists[0].tracks.map(\.id) == ["vid3", "vid1"])
        #expect(reloaded.history.count == 4)
        #expect(reloaded.searchHistory == ["radiohead", "Muse"])
        #expect(reloaded.settings.crossfadeSeconds == 6)
        #expect(reloaded.settings.eqPreset == .bassBoost)
        #expect(reloaded.settings.streamQuality == .lossless)

        // JSON backup round-trip into an empty database
        let backupData = try reloaded.exportBackupJSON()
        let dir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }

        let restored = LibraryStore(baseDirectory: dir2)
        #expect(restored.likedTracks.isEmpty)
        try restored.importBackupJSON(backupData)

        #expect(restored.likedTracks.map(\.id) == [t2.id])
        #expect(restored.playlists.count == 1)
        #expect(restored.playlists[0].title == "Midnight Coding")
        #expect(restored.history.count == 4)
        #expect(restored.searchHistory == ["radiohead", "Muse"])
        #expect(restored.settings.crossfadeSeconds == 6)

        // Verify imported backup was also persisted to SQLite
        let restoredReloaded = LibraryStore(baseDirectory: dir2)
        #expect(restoredReloaded.playlists.first?.title == "Midnight Coding")
        #expect(restoredReloaded.history.count == 4)
    }
}

// MARK: - 4. DiscordRPC IPC Packet Framing Tests

@Suite("DiscordRPC IPC Packet Framing")
struct DiscordRPCFramingTests {

    private struct DecodedIPCFrame: Sendable {
        let opcode: UInt32
        let jsonData: Data
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    private static func readIPCFrame(fd: Int32) -> DecodedIPCFrame? {
        guard let header = readExact(fd: fd, count: 8) else { return nil }
        let opcode = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian
        guard length <= 1_048_576 else { return nil }
        let body = length > 0 ? (readExact(fd: fd, count: Int(length)) ?? Data()) : Data()
        return DecodedIPCFrame(opcode: opcode, jsonData: body)
    }

    private static func writeIPCFrame(fd: Int32, opcode: UInt32, jsonObject: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: jsonObject) else { return false }
        var packet = Data(capacity: 8 + body.count)
        var opLE = opcode.littleEndian
        var lenLE = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &opLE) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLE) { packet.append(contentsOf: $0) }
        packet.append(body)
        return packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < packet.count {
                let n = Darwin.send(fd, base.advanced(by: sent), packet.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    @Test("Direct little-endian [opcode, length, JSON] frame encoding and decoding")
    func testDiscordIPCEncodeDecodeFraming() throws {
        let payloadObj: [String: Any] = ["v": 1, "client_id": DiscordRPC.defaultClientId]
        let frame = try #require(DiscordRPC.encodeFrame(opcode: 0, jsonObject: payloadObj))
        #expect(frame.count > 8)

        // Verify exact little-endian wire layout: bytes 0..<4 opcode, 4..<8 length
        let rawOpcode = frame.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let rawLength = frame.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian
        #expect(rawOpcode == 0)
        #expect(Int(rawLength) == frame.count - 8)

        let decoded = try #require(DiscordRPC.decodeFrame(from: frame))
        #expect(decoded.opcode == 0)
        let decodedJSON = try #require(try JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any])
        #expect((decodedJSON["v"] as? Int) == 1)
        #expect((decodedJSON["client_id"] as? String) == DiscordRPC.defaultClientId)

        // Truncated header or truncated payload must return nil
        #expect(DiscordRPC.decodeFrame(from: Data([0, 0, 0])) == nil)
        #expect(DiscordRPC.decodeFrame(from: frame.prefix(frame.count - 1)) == nil)
    }

    @Test("End-to-end socketpair handshake, SET_ACTIVITY, clearPresence, and disconnect framing")
    func testDiscordIPCEndToEndFraming() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let clientFD = fds[0]
        let serverFD = fds[1]

        // Run mock Discord IPC peer on serverFD collecting all client frames
        let serverTask = Task.detached { () -> [DecodedIPCFrame] in
            defer { Darwin.close(serverFD) }
            var frames: [DecodedIPCFrame] = []
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            // 1. Expect handshake (opcode 0)
            if let handshake = Self.readIPCFrame(fd: serverFD) {
                frames.append(handshake)
                _ = Self.writeIPCFrame(fd: serverFD, opcode: 1, jsonObject: [
                    "cmd": "DISPATCH",
                    "evt": "READY",
                    "data": ["v": 1]
                ])
            }

            // 2. Read subsequent frames until close (opcode 2) or EOF
            while let frame = Self.readIPCFrame(fd: serverFD) {
                frames.append(frame)
                if frame.opcode == 2 { break }
                _ = Self.writeIPCFrame(fd: serverFD, opcode: 1, jsonObject: ["cmd": "SET_ACTIVITY", "data": [:]])
            }
            return frames
        }

        let rpc = DiscordRPC(clientId: DiscordRPC.defaultClientId)
        await rpc.attachConnectedSocketForTesting(clientFD)
        #expect(await rpc.isConnected == true)

        let track = makeSampleTrack(id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "Rick Astley", album: "Whenever You Need Somebody", duration: 213)
        let stream = ResolvedStream(
            url: URL(string: "https://example.invalid/a.m4a")!,
            mimeType: "audio/mp4",
            codec: "AAC",
            bitrateKbps: 256,
            sampleRateHz: 44100,
            bitDepth: 16,
            clientName: "IOS",
            qualityLabel: "High"
        )
        var settings = AppSettings.default
        settings.discordRPCEnabled = true
        settings.discordShowButtons = true

        // Send Listening presence
        await rpc.updatePresence(track: track, stream: stream, isPlaying: true, elapsed: 42, duration: 213, settings: settings)
        // Pause clears presence
        await rpc.updatePresence(track: track, stream: stream, isPlaying: false, elapsed: 42, duration: 213, settings: settings)
        // Disconnect sends opcode 2
        await rpc.disconnect()
        #expect(await rpc.isConnected == false)

        let captured = await serverTask.value
        #expect(captured.count == 4)

        // Frame 0: Handshake
        #expect(captured[0].opcode == 0)
        let hsJSON = try #require(try JSONSerialization.jsonObject(with: captured[0].jsonData) as? [String: Any])
        #expect((hsJSON["v"] as? Int) == 1)
        #expect((hsJSON["client_id"] as? String) == DiscordRPC.defaultClientId)

        // Frame 1: SET_ACTIVITY (Listening)
        #expect(captured[1].opcode == 1)
        let actJSON = try #require(try JSONSerialization.jsonObject(with: captured[1].jsonData) as? [String: Any])
        #expect((actJSON["cmd"] as? String) == "SET_ACTIVITY")
        let args = try #require(actJSON["args"] as? [String: Any])
        let activity = try #require(args["activity"] as? [String: Any])
        #expect((activity["type"] as? Int) == 2)
        #expect((activity["details"] as? String) == "Never Gonna Give You Up")
        #expect((activity["state"] as? String) == "Rick Astley")
        let timestamps = try #require(activity["timestamps"] as? [String: Any])
        #expect(timestamps["start"] != nil && timestamps["end"] != nil)
        let buttons = try #require(activity["buttons"] as? [[String: String]])
        #expect(buttons.first?["url"] == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")

        // Frame 2: SET_ACTIVITY (Cleared on pause)
        #expect(captured[2].opcode == 1)
        let clearJSON = try #require(try JSONSerialization.jsonObject(with: captured[2].jsonData) as? [String: Any])
        let clearArgs = try #require(clearJSON["args"] as? [String: Any])
        #expect(clearArgs["activity"] is NSNull)

        // Frame 3: Close
        #expect(captured[3].opcode == 2)
    }
}

// MARK: - 5. AudioEngine Queue, Shuffle, Repeat, EQ, and Crossfade Tests

@Suite("AudioEngine Queue & DSP Controls")
@MainActor
struct AudioEngineTests {

    @Test("Queue operations, shuffle/unshuffle preservation, repeat cycling")
    func testQueueShuffleAndRepeat() {
        let engine = AudioEngine(streamResolver: StubStreamResolver())
        let tracks = (1...5).map { makeSampleTrack(id: "t\($0)", title: "Track \($0)") }

        for t in tracks {
            engine.addToQueue(t, playNext: false)
        }
        #expect(engine.queue.map(\.id) == ["t1", "t2", "t3", "t4", "t5"])
        #expect(engine.currentIndex == 0)

        // Play Next inserts right after currentIndex (at index 1)
        let urgent = makeSampleTrack(id: "urgent", title: "Urgent")
        engine.addToQueue(urgent, playNext: true)
        #expect(engine.queue.map(\.id) == ["t1", "urgent", "t2", "t3", "t4", "t5"])

        // Reorder moves index 5 ("t5") to index 1
        engine.reorderQueue(from: IndexSet(integer: 5), to: 1)
        #expect(engine.queue[1].id == "t4" || engine.queue.count == 6)
        #expect(engine.queue[0].id == "t1")

        // Remove non-current track
        engine.removeFromQueue(at: 1)
        #expect(engine.queue.count == 5)
        #expect(engine.currentIndex == 0)

        // Shuffle keeps active track at index 0 & preserves exact set of IDs
        let preShuffleIDs = engine.queue.map(\.id)
        engine.toggleShuffle()
        #expect(engine.isShuffled)
        #expect(engine.queue.first?.id == preShuffleIDs.first)
        #expect(Set(engine.queue.map(\.id)) == Set(preShuffleIDs))

        // Unshuffle restores original order
        engine.toggleShuffle()
        #expect(!engine.isShuffled)
        #expect(engine.queue.map(\.id) == preShuffleIDs)

        // Repeat cycling: off -> all -> one -> off
        #expect(engine.repeatMode == .off)
        engine.cycleRepeatMode()
        #expect(engine.repeatMode == .all)
        engine.cycleRepeatMode()
        #expect(engine.repeatMode == .one)
        engine.cycleRepeatMode()
        #expect(engine.repeatMode == .off)

        // Clear queue resets state
        engine.clearQueue()
        #expect(engine.queue.isEmpty)
        #expect(engine.currentTrack == nil)
        #expect(!engine.isPlaying)
    }

    @Test("EQ presets, clamping, balance, crossfade, playback rate, volume, and sleep timer")
    func testEQCrossfadeAndPlaybackControls() {
        let engine = AudioEngine(streamResolver: StubStreamResolver())

        // Verify all 16 EQ presets have 7 bands and round-trip matching
        #expect(EQPreset.allCases.count == 16)
        for preset in EQPreset.allCases {
            #expect(preset.gains.count == EQBand.defaultFrequencies.count)
            if preset != .custom {
                #expect(EQPreset.matching(gains: preset.gains) == preset)
            }
        }

        // Apply EQ + out-of-range clamping
        engine.applyEQ(enabled: true, gains: [20, -25, 3, 0, 1.5, -4, 12], balance: 2.5)
        #expect(engine.eqEnabled == true)
        #expect(engine.eqGains == [12, -12, 3, 0, 1.5, -4, 12])
        #expect(engine.balance == 1.0)

        engine.applyEQ(enabled: false, gains: EQPreset.vocal.gains, balance: -3.0)
        #expect(engine.eqEnabled == false)
        #expect(engine.eqGains == EQPreset.vocal.gains)
        #expect(engine.balance == -1.0)

        // Loudness normalization
        engine.setLoudnessNormalization(false)
        #expect(engine.loudnessNormalization == false)
        engine.setLoudnessNormalization(true)
        #expect(engine.loudnessNormalization == true)

        // Crossfade clamping [0, 12]
        engine.setCrossfade(8.5)
        #expect(engine.crossfadeSeconds == 8.5)
        engine.setCrossfade(99)
        #expect(engine.crossfadeSeconds == 12)
        engine.setCrossfade(-5)
        #expect(engine.crossfadeSeconds == 0)

        // Playback rate clamping [0.5, 2.0]
        engine.setPlaybackRate(1.25)
        #expect(engine.playbackRate == 1.25)
        engine.setPlaybackRate(4.0)
        #expect(engine.playbackRate == 2.0)
        engine.setPlaybackRate(0.1)
        #expect(engine.playbackRate == 0.5)

        // Volume & Mute
        engine.setVolume(0.5)
        #expect(engine.volume == 0.5)
        engine.toggleMute()
        #expect(engine.isMuted == true)
        engine.setVolume(0.7) // unmutes when setting > 0
        #expect(engine.isMuted == false)
        #expect(engine.volume == 0.7)

        // Sleep timer
        engine.setSleepTimer(minutes: 15)
        #expect(engine.sleepTimerRemaining == 900)
        engine.setSleepTimer(minutes: nil)
        #expect(engine.sleepTimerRemaining == nil)
    }

    @Test("AudioEngine customStreamResolver hook takes priority and adopts authoritative stream durationSeconds")
    func testCustomStreamResolverAndDurationAdoption() async {
        let stub = StubStreamResolver()
        let engine = AudioEngine(streamResolver: stub)
        engine.setVolume(0)

        var customCalledForTrack: String?
        engine.customStreamResolver = { track, _ in
            customCalledForTrack = track.id
            return ResolvedStream(
                url: URL(string: "https://cdn.example.invalid/lossless.flac")!,
                mimeType: "audio/flac",
                codec: "flac",
                bitrateKbps: 1411,
                sampleRateHz: 88_200,
                bitDepth: 24,
                clientName: "ADDON:Resonance",
                qualityLabel: "Hi-Res Lossless",
                isHLS: false,
                durationSeconds: 248.69
            )
        }

        let track = makeSampleTrack(id: "yt_123", title: "Get Lucky", artist: "Daft Punk", duration: 0)
        await engine.play(track: track, queue: [track])

        #expect(customCalledForTrack == "yt_123")
        #expect(stub.resolveCount == 0) // customStreamResolver satisfied playback without calling YouTube resolver
        #expect(engine.currentStreamInfo?.clientName == "ADDON:Resonance")
        #expect(engine.currentStreamInfo?.codec == "flac")
        #expect(abs(engine.duration - 248.69) < 0.01)

        engine.clearQueue()
    }

    @Test("AudioEngine publishes macOS Now Playing metadata, MediaType, playbackState, and MPRemoteCommandCenter state")
    func testNowPlayingAndRemoteCommands() async {
        let stub = StubStreamResolver()
        let engine = AudioEngine(streamResolver: stub)
        engine.setVolume(0)
        engine.ensureRemoteCommandsRegistered()

        let remote = MPRemoteCommandCenter.shared()
        #expect(remote.playCommand.isEnabled)
        #expect(remote.pauseCommand.isEnabled)
        #expect(remote.togglePlayPauseCommand.isEnabled)

        engine.customStreamResolver = { _, _ in
            ResolvedStream(
                url: URL(string: "https://cdn.example.invalid/panasea.m4a")!,
                mimeType: "audio/mp4",
                codec: "aac",
                bitrateKbps: 256,
                clientName: "IOS",
                qualityLabel: "256 kbps AAC",
                isHLS: false,
                durationSeconds: 215.0
            )
        }

        let track1 = makeSampleTrack(id: "rumahsakit_panasea", title: "Panasea", artist: "rumahsakit", album: "1+2", duration: 215.0)
        let track2 = makeSampleTrack(id: "rumahsakit_hilang", title: "Hilang", artist: "rumahsakit", album: "1+2", duration: 240.0)
        await engine.play(track: track1, queue: [track1, track2])

        let center = MPNowPlayingInfoCenter.default()
        let info = center.nowPlayingInfo
        #expect(info != nil)
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Panasea")
        #expect(info?[MPMediaItemPropertyArtist] as? String == "rumahsakit")
        #expect(info?[MPMediaItemPropertyAlbumTitle] as? String == "1+2")
        #expect(info?[MPMediaItemPropertyAlbumArtist] as? String == "rumahsakit")
        #expect(info?[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(info?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == "rumahsakit_panasea")
        #expect((info?[MPMediaItemPropertyPersistentID] as? NSNumber)?.uint64Value ?? 0 != 0)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 0)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 2)
        #expect(abs((info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0) - 215.0) < 0.01)
        #expect(center.playbackState == .playing)

        // Pause updates playbackState and sets rate to 0
        engine.pause()
        #expect(center.playbackState == .paused)
        #expect((center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0.0)

        // Shuffle & repeat sync to MPRemoteCommandCenter
        engine.toggleShuffle()
        #expect(remote.changeShuffleModeCommand.currentShuffleType == .items)
        engine.cycleRepeatMode()
        #expect(remote.changeRepeatModeCommand.currentRepeatType == .all)

        // Clear queue / shutdown clears Now Playing cleanly
        engine.clearQueue()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }
}

// MARK: - 6. StreamResolver Quality Selection, Client Fallback & Cache Tests

private final class MockPlayerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _requestCount: Int = 0

    static func configure(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        _handler = handler
        _requestCount = 0
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self._handler
        if request.url?.path.contains("/youtubei/v1/player") == true {
            Self._requestCount += 1
        }
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("StreamResolver & AudioQuality", .serialized)
struct StreamResolverTests {

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPlayerURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makePlayerResponseJSON(formats: [[String: Any]], hlsURL: String? = nil) throws -> Data {
        var streamingData: [String: Any] = [
            "expiresInSeconds": "21540",
            "adaptiveFormats": formats
        ]
        if let hlsURL {
            streamingData["hlsManifestUrl"] = hlsURL
        }
        let root: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": streamingData
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("Quality selection picks AVFoundation-native AAC formats matching AudioQuality ceilings")
    func testQualitySelectionAcrossBitrates() async throws {
        let futureExpire = Int(Date().timeIntervalSince1970) + 7200
        let formats: [[String: Any]] = [
            [
                "itag": 139,
                "url": "https://cdn.example.invalid/audio139?expire=\(futureExpire)",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.5\"",
                "averageBitrate": 48_000,
                "audioSampleRate": "22050",
                "contentLength": "1200000"
            ],
            [
                "itag": 140,
                "url": "https://cdn.example.invalid/audio140?expire=\(futureExpire)",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "averageBitrate": 128_000,
                "audioSampleRate": "44100",
                "contentLength": "3200000"
            ],
            [
                "itag": 141,
                "url": "https://cdn.example.invalid/audio141?expire=\(futureExpire)",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "averageBitrate": 256_000,
                "audioSampleRate": "44100",
                "contentLength": "6400000"
            ],
            // WebM/Opus must be ignored for AVFoundation native selection
            [
                "itag": 251,
                "url": "https://cdn.example.invalid/audio251?expire=\(futureExpire)",
                "mimeType": "audio/webm; codecs=\"opus\"",
                "averageBitrate": 160_000,
                "audioSampleRate": "48000"
            ],
            // Muxed video/mp4 must lose to audio-only adaptive streams
            [
                "itag": 18,
                "url": "https://cdn.example.invalid/video18?expire=\(futureExpire)",
                "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                "bitrate": 500_000
            ]
        ]
        let responseData = try makePlayerResponseJSON(formats: formats)

        MockPlayerURLProtocol.configure { request in
            let url = request.url ?? URL(string: "https://www.youtube.com")!
            if url.path.contains("sw.js_data") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data("CgtestVisitorData1234567890123456789012345678901234".utf8))
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, responseData)
        }

        let resolver = StreamResolver(session: makeMockSession(), skipMediaProbe: true)

        let low = try await resolver.resolveStream(videoId: "qtest", quality: .low)
        #expect(low.bitrateKbps == 48)
        #expect(low.url.path.contains("audio139"))
        #expect(low.clientName == "VISIONOS_0_1")
        #expect(low.requestHeaders.isEmpty)

        let med = try await resolver.resolveStream(videoId: "qtest", quality: .medium)
        #expect(med.bitrateKbps == 128)
        #expect(med.url.path.contains("audio140"))

        let high = try await resolver.resolveStream(videoId: "qtest", quality: .high)
        #expect(high.bitrateKbps == 256)
        #expect(high.url.path.contains("audio141"))
        #expect(high.qualityLabel == "High")
        #expect(abs(high.expiresAt.timeIntervalSince1970 - Double(futureExpire)) < 2.0)

        let lossless = try await resolver.resolveStream(videoId: "qtest", quality: .lossless)
        #expect(lossless.bitrateKbps == 256)
        #expect(lossless.url.path.contains("audio141"))
    }

    @Test("StreamResolver TTL cache deduplicates repeat requests, invalidate(videoId:) evicts selectively, and clearCache clears all")
    func testStreamCacheAndInvalidation() async throws {
        let futureExpire = Int(Date().timeIntervalSince1970) + 7200
        let responseData = try makePlayerResponseJSON(formats: [[
            "itag": 140,
            "url": "https://cdn.example.invalid/cached140?expire=\(futureExpire)&dur=248.685",
            "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
            "averageBitrate": 128_000,
            "audioSampleRate": "44100",
            "approxDurationMs": "248685"
        ]])

        MockPlayerURLProtocol.configure { request in
            let url = request.url ?? URL(string: "https://www.youtube.com")!
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, url.path.contains("sw.js_data") ? Data() : responseData)
        }

        let resolver = StreamResolver(session: makeMockSession(), skipMediaProbe: true)

        let first = try await resolver.resolveStream(videoId: "cacheVid1", quality: .high)
        #expect(MockPlayerURLProtocol.requestCount == 1)
        #expect(abs((first.durationSeconds ?? 0) - 248.685) < 0.01)

        // Second track cached separately
        _ = try await resolver.resolveStream(videoId: "cacheVid2", quality: .high)
        #expect(MockPlayerURLProtocol.requestCount == 2)

        // Second call for cacheVid1 hits TTL cache (no additional network call)
        let second = try await resolver.resolveStream(videoId: "cacheVid1", quality: .high)
        #expect(first.url == second.url)
        #expect(MockPlayerURLProtocol.requestCount == 2)

        // Selective invalidation evicts only cacheVid1, preserving cacheVid2
        await resolver.invalidate(videoId: "cacheVid1")
        _ = try await resolver.resolveStream(videoId: "cacheVid2", quality: .high)
        #expect(MockPlayerURLProtocol.requestCount == 2)
        _ = try await resolver.resolveStream(videoId: "cacheVid1", quality: .high)
        #expect(MockPlayerURLProtocol.requestCount == 3)

        // Clearing cache forces a fresh fetch
        await resolver.clearCache()
        let third = try await resolver.resolveStream(videoId: "cacheVid1", quality: .high)
        #expect(third.url == first.url)
        #expect(MockPlayerURLProtocol.requestCount == 4)
    }

    @Test("Client fallback (VISIONOS -> IOS -> ANDROID_VR), 1 MiB media probe rejection of 403 URL, and HLS manifest fallback")
    func testClientAndHLSFallback() async throws {
        let futureExpire = Int(Date().timeIntervalSince1970) + 7200
        let vrData = try makePlayerResponseJSON(formats: [[
            "itag": 140,
            "url": "https://cdn.example.invalid/vr140?expire=\(futureExpire)",
            "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
            "averageBitrate": 128_000,
            "audioSampleRate": "44100",
            "approxDurationMs": "213089"
        ]])
        let unplayableData = try JSONSerialization.data(withJSONObject: [
            "playabilityStatus": ["status": "UNPLAYABLE", "reason": "Client blocked"]
        ])

        MockPlayerURLProtocol.configure { request in
            let url = request.url ?? URL(string: "https://www.youtube.com")!
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.contains("sw.js_data") {
                return (resp, Data("CgtestVisitorData1234567890123456789012345678901234".utf8))
            }
            let clientHeader = request.value(forHTTPHeaderField: "X-YouTube-Client-Name")
            // Reject VISIONOS (101) and IOS (5) so ANDROID_VR (28) wins
            if clientHeader == "101" || clientHeader == "5" {
                return (resp, unplayableData)
            }
            return (resp, vrData)
        }

        let resolver = StreamResolver(session: makeMockSession(), skipMediaProbe: true)
        let resolved = try await resolver.resolveStream(videoId: "fallbackVid", quality: .medium)
        #expect(resolved.clientName == "ANDROID_VR")
        #expect(resolved.url.path.contains("vr140"))
        #expect(resolved.requestHeaders["User-Agent"]?.contains("oculus") == true)
        #expect(abs((resolved.durationSeconds ?? 0) - 213.089) < 0.01)

        // Now verify the 1 MiB media probe rejects a 403-trapped direct URL and falls back to HLS!
        let badDirectPlusHLS = try makePlayerResponseJSON(
            formats: [[
                "itag": 140,
                "url": "https://cdn.example.invalid/trapped140?expire=\(futureExpire)",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "averageBitrate": 128_000,
                "audioSampleRate": "44100",
                "contentLength": "4025466"
            ]],
            hlsURL: "https://manifest.example.invalid/index.m3u8?expire=\(futureExpire)"
        )
        MockPlayerURLProtocol.configure { request in
            let url = request.url ?? URL(string: "https://www.youtube.com")!
            if url.path.contains("sw.js_data") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data("CgtestVisitorData1234567890123456789012345678901234".utf8))
            }
            if url.path.contains("trapped140") {
                // Simulate YouTube CDN rejecting the 1 MiB range probe with HTTP 403
                let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? ""
                let code = rangeHeader.hasPrefix("bytes=1048576-") ? 403 : 206
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": code == 206 ? "audio/mp4" : "text/plain"]
                )!
                return (resp, code == 206 ? Data(repeating: 0xAA, count: 2048) : Data())
            }
            if url.path.contains("index.m3u8") {
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/vnd.apple.mpegurl"]
                )!
                return (resp, Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8))
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, badDirectPlusHLS)
        }

        let probingResolver = StreamResolver(session: makeMockSession(), skipMediaProbe: false)
        let hlsStream = try await probingResolver.resolveStream(videoId: "probedHlsVid", quality: .high)
        #expect(hlsStream.isHLS == true)
        #expect(hlsStream.qualityLabel == "HLS")
        #expect(hlsStream.url.path.contains("index.m3u8"))
    }

    @Test("Empty video ID throws streamUnavailable and clearCache succeeds")
    func testEmptyVideoIdAndCacheClear() async {
        let resolver = StreamResolver()
        await resolver.clearCache()

        do {
            _ = try await resolver.resolveStream(videoId: "   ", quality: .high)
            Issue.record("Expected empty videoId to throw streamUnavailable")
        } catch let error as BitChordError {
            if case .streamUnavailable = error {
                // Expected
            } else {
                Issue.record("Unexpected BitChordError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("AudioQuality bitrate ceilings and ResolvedStream expiry/formatting")
    func testAudioQualityAndResolvedStream() {
        #expect(AudioQuality.low.maxBitrateKbps == 64)
        #expect(AudioQuality.medium.maxBitrateKbps == 128)
        #expect(AudioQuality.high.maxBitrateKbps == 256)
        #expect(AudioQuality.lossless.maxBitrateKbps == Int.max)

        let fresh = ResolvedStream(
            url: URL(string: "https://example.invalid/stream.m4a")!,
            mimeType: "audio/mp4",
            codec: "AAC",
            bitrateKbps: 256,
            sampleRateHz: 44100,
            bitDepth: 16,
            expiresAt: Date().addingTimeInterval(3600),
            clientName: "IOS",
            qualityLabel: "High"
        )
        #expect(!fresh.isExpired)
        #expect(fresh.formattedSummary.contains("256 kbps"))
        #expect(fresh.formattedSummary.contains("AAC"))

        let expired = ResolvedStream(
            url: URL(string: "https://example.invalid/old.m4a")!,
            mimeType: "audio/mp4",
            codec: "AAC",
            bitrateKbps: 128,
            expiresAt: Date().addingTimeInterval(30), // within 60s safety margin
            clientName: "IOS",
            qualityLabel: "Standard"
        )
        #expect(expired.isExpired)
    }
}

// MARK: - 7. Addons, Manifest Decoding, TrackMatcher & Persistence Tests

private final class MockAddonURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func configure(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self._handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Addons, Manifest Decoding & TrackMatcher", .serialized)
struct AddonSystemTests {

    @Test("AddonClient URL normalization preserves case-sensitive tokens and strips manifest/trailing slashes")
    func testAddonURLNormalization() {
        #expect(AddonClient.normalizeBase("https://www.resonance.web.id/manifest.json") == "https://www.resonance.web.id")
        #expect(AddonClient.normalizeBase("https://www.resonance.web.id///") == "https://www.resonance.web.id")
        #expect(AddonClient.normalizeBase("https://tido.example.org/AbCdEf123/manifest.json") == "https://tido.example.org/AbCdEf123")
        #expect(AddonClient.normalizeBase("https://tido.example.org/AbCdEf123/custom.json?v=2") == "https://tido.example.org/AbCdEf123")
        #expect(AddonClient.manifestURL(forBase: "https://tido.example.org/AbCdEf123/") == "https://tido.example.org/AbCdEf123/manifest.json")

        // Canonical URL lowercases scheme+host, drops default port, keeps exact path token case
        #expect(AddonClient.canonicalURL("HTTPS://Tido.Example.ORG:443/AbCdEf123/manifest.json") == "https://tido.example.org/AbCdEf123")
        #expect(AddonClient.canonicalURL("https://tido.example.org/abcdef123") != AddonClient.canonicalURL("https://tido.example.org/AbCdEf123"))
    }

    @Test("AddonManifest flexible 0/1/bool decoding and AddonStream sampleRate/bitrate normalization")
    func testAddonManifestAndStreamDecoding() throws {
        let manifestJSON = """
        {
          "id": "dev.resonance.hifi",
          "name": "Resonance",
          "version": "3.0.0",
          "description": "Qobuz Hi-Res + TIDAL",
          "resources": ["search", "stream"],
          "allowDownloads": 1,
          "checkValidLossless": 0,
          "bitchordAuth": false,
          "settings": [
            {
              "key": "quality",
              "type": "select",
              "label": "Audio quality",
              "default": "lossless",
              "options": [
                {"value": "lossless", "label": "Lossless"},
                {"value": "hires_only", "label": "Hi-Res Only"},
                {"value": "high", "label": "High"}
              ]
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(manifestJSON.utf8))
        #expect(manifest.id == "dev.resonance.hifi")
        #expect(manifest.displayName == "Resonance")
        #expect(manifest.isPlayable)
        #expect(manifest.allowDownloads == true)
        #expect(manifest.checkValidLossless == false)
        #expect(manifest.requiresBitChordAuth == false)
        #expect(manifest.qualityOptions.map(\.value) == ["lossless", "hires_only", "high"])
        #expect(manifest.defaultSettingsMap["quality"] == "lossless")

        // Test string/int boolean variants & bitchordAuth=1
        let authManifestJSON = """
        {"id":"auth.test","name":"AuthAddon","resources":["search"],"allowDownloads":0,"checkValidLossless":"true","bitchordAuth":1}
        """
        let authManifest = try JSONDecoder().decode(AddonManifest.self, from: Data(authManifestJSON.utf8))
        #expect(authManifest.allowDownloads == false)
        #expect(authManifest.checkValidLossless == true)
        #expect(authManifest.requiresBitChordAuth == true)

        // AddonStream normalization (kHz -> Hz, bps -> kbps, encrypted, dash)
        let streamJSON = """
        {
          "url": "https://cdn.example.invalid/track.flac",
          "codec": "flac",
          "sampleRate": 88.2,
          "bitDepth": 24,
          "bitrate": 2822000,
          "manifest": "none",
          "encrypted": false
        }
        """
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(streamJSON.utf8))
        #expect(stream.normalizedSampleRateHz == 88_200)
        #expect(stream.normalizedBitDepth == 24)
        #expect(stream.normalizedBitrateKbps == 2822)
        #expect(stream.resolvedQualityLabel == "Hi-Res Lossless")
        #expect(stream.transport == nil)
        #expect(stream.encrypted == false)
    }

    @Test("TrackMatcher enforces version-marker compatibility, artist overlap, and duration tolerance")
    func testTrackMatcherRules() {
        let target = Track(
            videoId: "5NV6Rdv1a3I",
            title: "Get Lucky (Official Audio) (feat. Pharrell Williams)",
            artist: "Daft Punk",
            album: "Random Access Memories",
            duration: 249
        )

        let exactHiRes = AddonTrack(
            id: "qo:1", title: "Get Lucky", artist: "Daft Punk, Pharrell Williams",
            album: "Random Access Memories", duration: 248.5, format: "flac",
            audioQuality: "HI_RES_LOSSLESS", bitDepth: 24, sampleRate: 88.2
        )
        let liveVersion = AddonTrack(
            id: "qo:2", title: "Get Lucky (Live at Grammys)", artist: "Daft Punk",
            album: "Live", duration: 249, format: "flac", audioQuality: "LOSSLESS"
        )
        let remixVersion = AddonTrack(
            id: "qo:3", title: "Get Lucky - Remix", artist: "Daft Punk",
            album: "Remixes", duration: 249, format: "flac", audioQuality: "LOSSLESS"
        )
        let instrumentalVersion = AddonTrack(
            id: "qo:4", title: "Get Lucky (Instrumental)", artist: "Daft Punk",
            album: "Single", duration: 249, format: "flac", audioQuality: "LOSSLESS"
        )
        let wrongDuration = AddonTrack(
            id: "qo:5", title: "Get Lucky", artist: "Daft Punk",
            album: "Random Access Memories", duration: 369, format: "flac", audioQuality: "LOSSLESS"
        )
        let wrongArtist = AddonTrack(
            id: "qo:6", title: "Get Lucky", artist: "Tribute Band",
            album: "Covers", duration: 254, format: "flac", audioQuality: "LOSSLESS"
        )

        #expect(TrackMatcher.score(candidate: exactHiRes, target: target, durationToleranceSec: 6.0) != nil)
        #expect(TrackMatcher.score(candidate: liveVersion, target: target, durationToleranceSec: 6.0) == nil)
        #expect(TrackMatcher.score(candidate: remixVersion, target: target, durationToleranceSec: 6.0) == nil)
        #expect(TrackMatcher.score(candidate: instrumentalVersion, target: target, durationToleranceSec: 6.0) == nil)
        #expect(TrackMatcher.score(candidate: wrongDuration, target: target, durationToleranceSec: 6.0) == nil)
        #expect(TrackMatcher.score(candidate: wrongArtist, target: target, durationToleranceSec: 6.0) == nil)

        let ranked = TrackMatcher.ranked(
            candidates: [liveVersion, remixVersion, instrumentalVersion, wrongDuration, wrongArtist, exactHiRes],
            target: target,
            durationToleranceSec: 6.0
        )
        #expect(ranked.map(\.id) == ["qo:1"])
    }

    @Test("AddonManager CRUD, priority reorder, duplicate check, and persistence to addons.json")
    @MainActor
    func testAddonManagerPersistenceAndCRUD() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordAddonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAddonURLProtocol.self]
        let mockClient = AddonClient(session: URLSession(configuration: config))

        MockAddonURLProtocol.configure { request in
            let url = request.url ?? URL(string: "https://addon-a.example.invalid/manifest.json")!
            let host = url.host ?? ""
            let payload: String
            if host.contains("addon-a") {
                payload = """
                {"id":"addon.a","name":"Addon Alpha","version":"1.2.0","resources":["search","stream"],"allowDownloads":1,"settings":[{"key":"quality","default":"lossless","options":[{"value":"lossless","label":"Lossless"},{"value":"high","label":"High"}]}]}
                """
            } else {
                payload = """
                {"id":"addon.b","name":"Addon Beta","version":"2.0.0","resources":["search","stream"],"allowDownloads":0}
                """
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, Data(payload.utf8))
        }

        let manager = AddonManager(baseDirectory: dir, client: mockClient)
        #expect(manager.addons.isEmpty)

        let alpha = try await manager.addAddon(from: "https://addon-a.example.invalid/manifest.json")
        let beta = try await manager.addAddon(from: "https://addon-b.example.invalid")
        #expect(manager.addons.map(\.name) == ["Addon Alpha", "Addon Beta"])
        #expect(manager.isInstalled(manifestOrBaseURL: "https://ADDON-A.example.invalid/"))

        // Duplicate URL must throw duplicateAddon
        do {
            _ = try await manager.addAddon(from: "https://addon-a.example.invalid")
            Issue.record("Expected duplicateAddon error")
        } catch AddonError.duplicateAddon {
            // Expected
        }

        // Priority reorder, toggle, quality update
        manager.moveAddon(id: beta.id, direction: .up)
        #expect(manager.addons.map(\.id) == [beta.id, alpha.id])
        manager.toggleAddon(id: alpha.id)
        manager.updatePreferredQuality(id: alpha.id, quality: "high")

        // Reload from disk in a fresh AddonManager instance
        let reloaded = AddonManager(baseDirectory: dir, client: mockClient)
        #expect(reloaded.addons.map(\.id) == [beta.id, alpha.id])
        #expect(reloaded.addons.first(where: { $0.id == alpha.id })?.isEnabled == false)
        #expect(reloaded.addons.first(where: { $0.id == alpha.id })?.preferredQuality == "high")

        reloaded.removeAddon(id: beta.id)
        #expect(reloaded.addons.count == 1)
    }
}

// MARK: - 7. ChordDetector DSP, Key Estimation & Guitar Diagram Tests

@Suite("ChordDetector DSP & Guitar Diagrams")
struct ChordDetectorTests {

    private static func midiFrequency(_ midi: Int) -> Double {
        440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// Synthesizes a clean multi-note sine-wave chord buffer (with gentle 2nd harmonic) at 44.1 kHz.
    private static func synthesizeChordBuffer(
        midiNotes: [Int],
        sampleCount: Int = 20_480,
        sampleRate: Double = 44_100,
        amplitude: Float = 0.25
    ) -> [Float] {
        var samples = Array(repeating: Float(0), count: sampleCount)
        let perNoteAmp = amplitude / Float(max(1, midiNotes.count))
        let twoPiOverSR = 2.0 * Double.pi / sampleRate
        for (idx, midi) in midiNotes.enumerated() {
            let f0 = midiFrequency(midi)
            let weight: Float = idx == 0 ? 1.25 : 1.0 // Bass root slightly emphasized
            for i in 0..<sampleCount {
                let phase = twoPiOverSR * f0 * Double(i)
                let fundamental = Float(sin(phase))
                let harmonic2 = 0.25 * Float(sin(2.0 * phase))
                samples[i] += perNoteAmp * weight * (fundamental + harmonic2)
            }
        }
        return samples
    }

    private static func feedAndStabilize(
        detector: ChordDetector,
        samples: [Float],
        sampleRate: Double = 44_100,
        simpleMode: Bool,
        frames: Int = 5,
        startTime: TimeInterval = 1.0
    ) -> ChordAnalysisSnapshot {
        var snapshot = ChordAnalysisSnapshot(chord: nil, chroma: Array(repeating: 0, count: 12), detectedKey: nil)
        for frame in 0..<frames {
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    detector.ingest(samples: base, count: samples.count, sampleRate: sampleRate)
                }
            }
            snapshot = detector.analyze(currentTime: startTime + Double(frame) * 0.125, simpleMode: simpleMode)
        }
        return snapshot
    }

    @Test("Accurate sine-wave detection for C Major, A Minor, F Major, and G7 (simple + extended)")
    func testSyntheticChordDetection() throws {
        let detector = ChordDetector()

        // 1. C Major: C3(48), G3(55), C4(60), E4(64), G4(67)
        let cMajorBuf = Self.synthesizeChordBuffer(midiNotes: [48, 55, 60, 64, 67])
        let cSnap = Self.feedAndStabilize(detector: detector, samples: cMajorBuf, simpleMode: true)
        let cChord = try #require(cSnap.chord)
        #expect(cChord.root == 0)
        #expect(cChord.quality == .major)
        #expect(cChord.displayName == "C")
        #expect(cChord.confidence > 0.5)
        #expect(cSnap.chroma.count == 12)
        #expect(!cSnap.isSilent)

        // 2. A Minor: A2(45), E3(52), A3(57), C4(60), E4(64)
        detector.reset()
        let aMinorBuf = Self.synthesizeChordBuffer(midiNotes: [45, 52, 57, 60, 64])
        let amSnap = Self.feedAndStabilize(detector: detector, samples: aMinorBuf, simpleMode: true)
        let amChord = try #require(amSnap.chord)
        #expect(amChord.root == 9)
        #expect(amChord.quality == .minor)
        #expect(amChord.displayName == "Am")
        #expect(amChord.noteNamesList == ["A", "C", "E"])

        // 3. F Major: F2(41), C3(48), F3(53), A3(57), C4(60)
        detector.reset()
        let fMajorBuf = Self.synthesizeChordBuffer(midiNotes: [41, 48, 53, 57, 60])
        let fSnap = Self.feedAndStabilize(detector: detector, samples: fMajorBuf, simpleMode: true)
        let fChord = try #require(fSnap.chord)
        #expect(fChord.root == 5)
        #expect(fChord.quality == .major)
        #expect(fChord.displayName == "F")

        // 4. G7 (Extended mode): G2(43), B3(59), D4(62), F4(65), G4(67)
        detector.reset()
        let g7Buf = Self.synthesizeChordBuffer(midiNotes: [43, 59, 62, 65, 67])
        let g7Snap = Self.feedAndStabilize(detector: detector, samples: g7Buf, simpleMode: false)
        let g7Chord = try #require(g7Snap.chord)
        #expect(g7Chord.root == 7)
        #expect(g7Chord.quality == .dominant7)
        #expect(g7Chord.displayName == "G7")
        #expect(g7Chord.noteNamesList == ["G", "B", "D", "F"])

        // 5. Stereo interleaved ingestion verifies identical accuracy
        detector.reset()
        var interleaved: [Float] = []
        interleaved.reserveCapacity(aMinorBuf.count * 2)
        for sample in aMinorBuf {
            interleaved.append(sample)
            interleaved.append(sample)
        }
        var stereoSnap = ChordAnalysisSnapshot(chord: nil, chroma: [], detectedKey: nil)
        for frame in 0..<5 {
            interleaved.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    detector.ingestInterleaved(samples: base, frameCount: aMinorBuf.count, channels: 2, sampleRate: 44_100)
                }
            }
            stereoSnap = detector.analyze(currentTime: Double(frame) * 0.125, simpleMode: true)
        }
        let stereoChord = try #require(stereoSnap.chord)
        #expect(stereoChord.root == 9)
        #expect(stereoChord.quality == .minor)
    }

    @Test("Silence gate clears chord and decays chroma on silent audio")
    func testSilenceGate() throws {
        let detector = ChordDetector()
        let cMajorBuf = Self.synthesizeChordBuffer(midiNotes: [48, 55, 60, 64, 67])
        let activeSnap = Self.feedAndStabilize(detector: detector, samples: cMajorBuf, simpleMode: true)
        #expect(activeSnap.chord?.displayName == "C")

        let silence = Array(repeating: Float(0), count: 20_480)
        var silentSnap = activeSnap
        for i in 0..<6 {
            silence.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    detector.ingest(samples: base, count: silence.count, sampleRate: 44_100)
                }
            }
            silentSnap = detector.analyze(currentTime: 5.0 + Double(i) * 0.125, simpleMode: true)
        }
        #expect(silentSnap.isSilent == true)
        #expect(silentSnap.chord == nil)
        #expect(silentSnap.rms < 0.001)
    }

    @Test("Krumhansl-Schmuckler running key estimation identifies C Major progression")
    func testKeyEstimation() throws {
        let detector = ChordDetector()
        // I - IV - V - vi - I progression in C Major
        let progression: [[Int]] = [
            [48, 55, 60, 64, 67], // C
            [41, 48, 53, 57, 60], // F
            [43, 50, 55, 59, 62], // G
            [45, 52, 57, 60, 64], // Am
            [48, 55, 60, 64, 67]  // C
        ]

        var lastSnap = ChordAnalysisSnapshot(chord: nil, chroma: [], detectedKey: nil)
        var t: TimeInterval = 0
        for notes in progression {
            let buf = Self.synthesizeChordBuffer(midiNotes: notes)
            lastSnap = Self.feedAndStabilize(
                detector: detector,
                samples: buf,
                simpleMode: true,
                frames: 5,
                startTime: t
            )
            t += 1.0
        }

        let key = try #require(lastSnap.detectedKey)
        #expect(key == "C Major")
    }

    @Test("Transposition math, display names, and RightDrawerTab.chords contract")
    func testTranspositionAndModelsContract() {
        #expect(RightDrawerTab.chords.id == "chords")
        #expect(RightDrawerTab.chords.title == "Chords")
        #expect(RightDrawerTab.chords.systemImage == "guitars")

        let am = DetectedChord(root: 9, quality: .minor, confidence: 0.92, timestamp: 12.5)
        #expect(am.rootName == "A")
        #expect(am.displayName == "Am")
        #expect(am.noteIndices == [9, 0, 4])
        #expect(am.noteNamesList == ["A", "C", "E"])

        let bm = am.transposed(by: 2)
        #expect(bm.root == 11)
        #expect(bm.displayName == "Bm")
        #expect(bm.timestamp == 12.5)

        let gm = am.transposed(by: -2)
        #expect(gm.root == 7)
        #expect(gm.displayName == "Gm")

        let wrapped = am.transposed(by: 12)
        #expect(wrapped.root == am.root)
        #expect(wrapped.displayName == "Am")
    }

    @Test("All 60 GuitarChordDiagram voicings (12 roots × 5 qualities) are structurally & musically valid")
    func testAll60GuitarChordDiagrams() {
        // Standard guitar tuning pitch classes (low E to high e): E, A, D, G, B, E
        let openStringPitchClasses = [4, 9, 2, 7, 11, 4]
        var checkedCount = 0

        for root in 0..<12 {
            for quality in ChordQuality.allCases {
                let chord = DetectedChord(root: root, quality: quality, confidence: 1.0, timestamp: 0)
                let diagram = chord.guitarDiagram
                let allowedPitchClasses = Set(chord.noteIndices)

                #expect(diagram.frets.count == 6, "Expected 6 strings for \(chord.displayName)")
                #expect(diagram.fingers.count == 6, "Expected 6 fingers for \(chord.displayName)")
                #expect(diagram.baseFret >= 1, "Invalid baseFret for \(chord.displayName)")

                if let barre = diagram.barreFret {
                    #expect(barre >= diagram.baseFret && barre <= diagram.baseFret + 3,
                            "Barre fret out of 4-fret window for \(chord.displayName)")
                }

                var soundedPitchClasses: [Int] = []
                for stringIdx in 0..<6 {
                    let fret = diagram.frets[stringIdx]
                    let finger = diagram.fingers[stringIdx]
                    if fret <= 0 {
                        #expect(fret == -1 || fret == 0, "Invalid fret \(fret) for \(chord.displayName)")
                        #expect(finger == 0, "Open/muted string must use finger 0 for \(chord.displayName)")
                    } else {
                        #expect(fret >= diagram.baseFret && fret <= diagram.baseFret + 3,
                                "Fret \(fret) outside [\(diagram.baseFret)...\(diagram.baseFret + 3)] for \(chord.displayName)")
                        #expect(finger >= 1 && finger <= 4, "Fretted finger must be 1...4 for \(chord.displayName)")
                    }

                    if fret >= 0 {
                        let pc = (openStringPitchClasses[stringIdx] + fret) % 12
                        #expect(allowedPitchClasses.contains(pc),
                                "String \(stringIdx) fret \(fret) produces pitch class \(pc) not in \(chord.displayName)")
                        soundedPitchClasses.append(pc)
                    }
                }

                #expect(soundedPitchClasses.count >= 3, "At least 3 strings should sound for \(chord.displayName)")
                #expect(soundedPitchClasses.first == root, "Lowest sounded note should be root for \(chord.displayName)")
                checkedCount += 1
            }
        }

        #expect(checkedCount == 60)
    }

    @Test("AudioEngine exposes chord properties and resetChordAnalysis clears state")
    @MainActor
    func testAudioEngineChordStateReset() {
        let engine = AudioEngine(streamResolver: StubStreamResolver())
        #expect(engine.currentChord == nil)
        #expect(engine.chordHistory.isEmpty)
        #expect(engine.detectedKey == nil)
        #expect(engine.chromaVector.count == 12)
        #expect(engine.chordSimpleMode == true)
        #expect(engine.chordTransposeSemitones == 0)

        engine.chordSimpleMode = false
        engine.chordTransposeSemitones = 2
        #expect(engine.chordSimpleMode == false)
        #expect(engine.chordTransposeSemitones == 2)

        engine.resetChordAnalysis()
        #expect(engine.currentChord == nil)
        #expect(engine.chordHistory.isEmpty)
        #expect(engine.detectedKey == nil)
        #expect(engine.chromaVector == Array(repeating: 0, count: 12))
    }

    @Test("AppleScriptBridge exposes Spotify-compatible track metadata and playback state")
    @MainActor
    func testAppleScriptBridgeMetadataAndRepeat() {
        let engine = AudioEngine(streamResolver: StubStreamResolver())
        AppleScriptBridge.shared.attach(audioEngine: engine)

        #expect(AppleScriptBridge.shared.currentPlayerStateCode() == AppleScriptBridge.stateStopped)
        #expect(AppleScriptBridge.shared.makeCurrentScriptableTrack() == nil)

        let track = Track(
            id: "vid123",
            videoId: "vid123",
            title: "Midnight Groove",
            artist: "The Bitchords",
            album: "Night Sessions",
            duration: 215.4,
            artworkURL: URL(string: "https://example.com/cover.jpg")
        )
        let scriptTrack = SoundChordScriptableTrack(track: track, durationSeconds: 215.4)
        #expect(scriptTrack.scriptTrackID == "vid123")
        #expect(scriptTrack.scriptTitle == "Midnight Groove")
        #expect(scriptTrack.scriptArtist == "The Bitchords")
        #expect(scriptTrack.scriptAlbum == "Night Sessions")
        #expect(scriptTrack.scriptDurationMs == 215400)
        #expect(scriptTrack.scriptArtworkURL == "https://example.com/cover.jpg")

        let localTrack = Track(
            id: "local1",
            videoId: "local1",
            title: "Local Song",
            artist: "Indie",
            duration: 120,
            artworkURL: URL(fileURLWithPath: "/tmp/cover.png")
        )
        let localScriptTrack = SoundChordScriptableTrack(track: localTrack, durationSeconds: 120)
        #expect(localScriptTrack.scriptArtworkURL == "")

        #expect(engine.repeatMode == .off)
        AppleScriptBridge.shared.setRepeating(true)
        #expect(engine.repeatMode != .off)
        AppleScriptBridge.shared.setRepeating(false)
        #expect(engine.repeatMode == .off)
    }

    @Test("ChordTimelineAnalyzer.analyzePCMBuffer decodes C -> G -> Am -> F progression, segment lookups, and C Major key")
    func testChordTimelineAnalyzerMultiBarProgression() throws {
        let sampleRate: Double = 22_050
        let secondsPerChord: Double = 2.0
        let samplesPerChord = Int(sampleRate * secondsPerChord)

        let progression: [(name: String, midiNotes: [Int])] = [
            ("C",  [48, 55, 60, 64, 67]),
            ("G",  [43, 50, 55, 59, 62]),
            ("Am", [45, 52, 57, 60, 64]),
            ("F",  [41, 48, 53, 57, 60])
        ]

        var fullBuffer: [Float] = []
        fullBuffer.reserveCapacity(samplesPerChord * progression.count)

        for item in progression {
            let chunk = Self.synthesizeChordBuffer(
                midiNotes: item.midiNotes,
                sampleCount: samplesPerChord,
                sampleRate: sampleRate
            )
            fullBuffer.append(contentsOf: chunk)
        }

        let timeline = ChordTimelineAnalyzer.analyzePCMBuffer(
            fullBuffer,
            sampleRate: sampleRate,
            trackId: "prog_track_1",
            simpleMode: true,
            knownDuration: 8.0
        )

        #expect(timeline.trackId == "prog_track_1")
        #expect(timeline.simpleMode == true)
        #expect(abs(timeline.duration - 8.0) < 0.05)
        #expect(timeline.key == "C Major")
        #expect(timeline.segments.count == 4)

        let detectedNames = timeline.segments.map(\.chord.displayName)
        #expect(detectedNames == ["C", "G", "Am", "F"])

        // Verify segment(at:) and nextSegment(after:) across each 2-second bar
        #expect(timeline.segment(at: 0.9)?.chord.displayName == "C")
        #expect(timeline.nextSegment(after: 0.9)?.chord.displayName == "G")

        #expect(timeline.segment(at: 2.9)?.chord.displayName == "G")
        #expect(timeline.nextSegment(after: 2.9)?.chord.displayName == "Am")

        #expect(timeline.segment(at: 4.9)?.chord.displayName == "Am")
        #expect(timeline.nextSegment(after: 4.9)?.chord.displayName == "F")

        #expect(timeline.segment(at: 6.9)?.chord.displayName == "F")
        #expect(timeline.nextSegment(after: 6.9) == nil)
    }

    @Test("LyricsChordAligner aligns word-synced and line-synced lyrics with Intro/Instrumental/Outro gaps, carrying chords, and offset")
    func testLyricsChordAlignerWordAndLineSynced() {
        let segC  = TimedChordSegment(chord: DetectedChord(root: 0, quality: .major, confidence: 0.95, timestamp: 0.0),  startTime: 0.0,  endTime: 6.0)
        let segG  = TimedChordSegment(chord: DetectedChord(root: 7, quality: .major, confidence: 0.92, timestamp: 6.0),  startTime: 6.0,  endTime: 12.0)
        let segAm = TimedChordSegment(chord: DetectedChord(root: 9, quality: .minor, confidence: 0.93, timestamp: 12.0), startTime: 12.0, endTime: 16.0)
        let segF  = TimedChordSegment(chord: DetectedChord(root: 5, quality: .major, confidence: 0.91, timestamp: 16.0), startTime: 16.0, endTime: 22.0)

        let timeline = TrackChordTimeline(
            trackId: "align_test",
            key: "C Major",
            bpm: 120.0,
            simpleMode: true,
            duration: 22.0,
            segments: [segC, segG, segAm, segF]
        )

        // Word-synced lyrics:
        // - Intro: [0.0 .. 4.0] (>= 2.5s -> "Intro" row with C)
        // - Line 1: [4.0 .. 8.0] words at 4.0..5.8 ("Hello"), 6.0..8.0 ("world")
        //   -> word 0 gets carrying chord C, word 1 gets mid-line chord change G at 6.0s!
        // - Instrumental gap: [8.0 .. 12.0] (4.0s >= 3.0s -> "Instrumental" row)
        // - Line 2: [12.0 .. 15.0] words at 12.0..13.5 ("Sing"), 13.5..15.0 ("along") -> word 0 gets Am
        // - Outro: [15.0 .. 22.0] (7.0s >= 3.0s -> "Outro" row with Am/F)
        let line1 = LyricLine(
            id: "l1",
            startTime: 4.0,
            endTime: 8.0,
            text: "Hello world",
            words: [
                LyricWord(id: "w1", startTime: 4.0, endTime: 5.8, text: "Hello"),
                LyricWord(id: "w2", startTime: 6.0, endTime: 8.0, text: "world")
            ]
        )
        let line2 = LyricLine(
            id: "l2",
            startTime: 12.0,
            endTime: 15.0,
            text: "Sing along",
            words: [
                LyricWord(id: "w3", startTime: 12.0, endTime: 13.5, text: "Sing"),
                LyricWord(id: "w4", startTime: 13.5, endTime: 15.0, text: "along")
            ]
        )
        let wordSyncedDoc = LyricsDocument(
            trackId: "align_test",
            provider: "TTML",
            isSynced: true,
            isWordSynced: true,
            lines: [line1, line2]
        )

        let rows = LyricsChordAligner.align(lyrics: wordSyncedDoc, timeline: timeline, lyricsOffsetSeconds: 0)
        #expect(rows.count == 5)

        // Row 0: Intro
        if case .instrumental(_, let label, let start, let end, let segs) = rows[0] {
            #expect(label == "Intro")
            #expect(start == 0.0)
            #expect(end == 4.0)
            #expect(segs.map(\.chord.displayName) == ["C"])
        } else {
            Issue.record("Expected Intro instrumental row at index 0")
        }

        // Row 1: Line 1 with carrying chord C on "Hello" and mid-line change G on "world"
        if case .lyric(_, _, _, _, let tokens, _) = rows[1] {
            #expect(tokens.count == 2)
            #expect(tokens[0].text == "Hello")
            #expect(tokens[0].chord?.displayName == "C")
            #expect(tokens[0].chordSegmentId == segC.id)
            #expect(tokens[1].text == "world")
            #expect(tokens[1].chord?.displayName == "G")
            #expect(tokens[1].chordSegmentId == segG.id)
        } else {
            Issue.record("Expected lyric row at index 1")
        }

        // Row 2: Instrumental break [8.0 .. 12.0]
        if case .instrumental(_, let label, let start, let end, let segs) = rows[2] {
            #expect(label == "Instrumental")
            #expect(start == 8.0)
            #expect(end == 12.0)
            #expect(!segs.isEmpty)
        } else {
            Issue.record("Expected inter-line Instrumental row at index 2")
        }

        // Row 3: Line 2 starting at 12.0s with Am on "Sing"
        if case .lyric(_, _, _, _, let tokens, _) = rows[3] {
            #expect(tokens.count == 2)
            #expect(tokens[0].text == "Sing")
            #expect(tokens[0].chord?.displayName == "Am")
            #expect(tokens[1].text == "along")
            #expect(tokens[1].chord == nil)
        } else {
            Issue.record("Expected lyric row at index 3")
        }

        // Row 4: Outro [15.0 .. 22.0]
        if case .instrumental(_, let label, let start, let end, let segs) = rows[4] {
            #expect(label == "Outro")
            #expect(start == 15.0)
            #expect(end == 22.0)
            #expect(segs.contains(where: { $0.chord.displayName == "F" }))
        } else {
            Issue.record("Expected Outro instrumental row at index 4")
        }

        // Verify lyricsOffsetSeconds shifts effective timestamps
        let shiftedRows = LyricsChordAligner.align(lyrics: wordSyncedDoc, timeline: timeline, lyricsOffsetSeconds: 1.0)
        #expect(shiftedRows[1].startTime == 5.0)

        // Line-synced fallback: proportional word timestamps place mid-line chord on matching word
        let lineSyncedDoc = LyricsDocument(
            trackId: "align_test",
            provider: "LRCLIB",
            isSynced: true,
            isWordSynced: false,
            lines: [
                LyricLine(id: "ls1", startTime: 4.0, endTime: 8.0, text: "One Two Three Four")
            ]
        )
        let lineRows = LyricsChordAligner.align(lyrics: lineSyncedDoc, timeline: timeline, lyricsOffsetSeconds: 0)
        let lyricRow = lineRows.first {
            if case .lyric = $0 { return true }
            return false
        }
        if case .lyric(_, _, _, _, let tokens, _) = lyricRow {
            #expect(tokens.count == 4)
            #expect(tokens[0].chord?.displayName == "C") // carrying chord at 4.0s
            #expect(tokens[2].chord?.displayName == "G") // G starts at 6.0s (midpoint -> word index 2)
        } else {
            Issue.record("Expected line-synced lyric row")
        }
    }

    @Test("LibraryStore SQLite chord_timelines round-trip persistence (save, load, delete)")
    @MainActor
    func testLibraryStoreChordTimelinePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordTimelineStoreTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LibraryStore(baseDirectory: tempDir)
        #expect(store.loadChordTimeline(trackId: "track_xyz") == nil)

        let seg1 = TimedChordSegment(
            chord: DetectedChord(root: 0, quality: .major, confidence: 0.91, timestamp: 0),
            startTime: 0.0,
            endTime: 4.0
        )
        let seg2 = TimedChordSegment(
            chord: DetectedChord(root: 9, quality: .minor7, confidence: 0.87, timestamp: 4.0),
            startTime: 4.0,
            endTime: 8.5
        )
        let timeline = TrackChordTimeline(
            trackId: "track_xyz",
            key: "C Major",
            bpm: 124.0,
            simpleMode: false,
            duration: 8.5,
            segments: [seg1, seg2],
            analyzedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        store.saveChordTimeline(timeline)

        let loaded = try #require(store.loadChordTimeline(trackId: "track_xyz"))
        #expect(loaded.trackId == "track_xyz")
        #expect(loaded.key == "C Major")
        #expect(loaded.bpm == 124.0)
        #expect(loaded.simpleMode == false)
        #expect(loaded.duration == 8.5)
        #expect(loaded.segments.count == 2)
        #expect(loaded.segments[0].chord.displayName == "C")
        #expect(loaded.segments[1].chord.displayName == "Am7")

        // Verify persistence across a new LibraryStore instance pointing to the same SQLite database
        let reloadedStore = LibraryStore(baseDirectory: tempDir)
        let reloaded = try #require(reloadedStore.loadChordTimeline(trackId: "track_xyz"))
        #expect(reloaded.segments.count == 2)
        #expect(reloaded.key == "C Major")

        reloadedStore.deleteChordTimeline(trackId: "track_xyz")
        #expect(reloadedStore.loadChordTimeline(trackId: "track_xyz") == nil)
    }

    @Test("Rust FFI ChordTimelineAnalyzer produces 4-beat grid, sections, BPM, key C Major, isPartial, and legacy Codable decoding")
    func testChordTimelineAnalyzerBeatGridSectionsAndBPM() throws {
        let sampleRate: Double = 22_050
        let beatPeriod: Double = 0.5 // 120 BPM (4 beats per 2.0s bar, 4.0s per chord -> 16.0s total)
        let secondsPerChord: Double = 4.0
        let samplesPerChord = Int(sampleRate * secondsPerChord)

        let progression: [[Int]] = [
            [48, 55, 60, 64, 67], // C
            [43, 50, 55, 59, 62], // G
            [45, 52, 57, 60, 64], // Am
            [41, 48, 53, 57, 60]  // F
        ]

        var fullBuffer: [Float] = []
        fullBuffer.reserveCapacity(samplesPerChord * progression.count)

        for notes in progression {
            var chunk = Self.synthesizeChordBuffer(
                midiNotes: notes,
                sampleCount: samplesPerChord,
                sampleRate: sampleRate,
                amplitude: 0.25
            )
            // Apply rhythmic beat-onset pulses every 0.5s (120 BPM) so onset ACF locks onto 120 BPM & 4/4 meter
            for i in 0..<chunk.count {
                let t = Double(i) / sampleRate
                let beatPhase = t.truncatingRemainder(dividingBy: beatPeriod)
                let env = Float(0.55 + 0.45 * exp(-beatPhase * 8.0))
                chunk[i] *= env
            }
            fullBuffer.append(contentsOf: chunk)
        }

        let timeline = ChordTimelineAnalyzer.analyzePCMBuffer(
            fullBuffer,
            sampleRate: sampleRate,
            trackId: "rust_ffi_grid_test",
            simpleMode: true,
            knownDuration: 16.0,
            isPartial: false
        )

        #expect(timeline.trackId == "rust_ffi_grid_test")
        #expect(timeline.isPartial == false)
        #expect(timeline.key == "C Major")
        #expect(timeline.segments.map(\.chord.displayName) == ["C", "G", "Am", "F"])

        let bpm = try #require(timeline.bpm)
        #expect(bpm >= 60.0 && bpm <= 180.0)
        #expect(abs(bpm - 120.0) <= 6.0)
        #expect(timeline.beatsPerBar == 4)
        #expect(timeline.beats.count >= 28)

        let firstBeat = try #require(timeline.beats.first)
        #expect(firstBeat.barIndex == 0)
        #expect(firstBeat.beatIndex == 0)
        #expect(firstBeat.isChordChange == true)
        #expect(firstBeat.chord?.displayName == "C")
        #expect(Set(timeline.beats.map(\.beatIndex)) == Set([0, 1, 2, 3]))
        #expect(timeline.beatIndex(at: firstBeat.startTime + 0.05) == 0)

        #expect(!timeline.sections.isEmpty)
        #expect(timeline.section(at: 1.0) != nil)
        #expect(timeline.uniqueChords.map(\.displayName) == ["C", "G", "Am", "F"])
        #expect(timeline.chordChangeSegments.map(\.chord.displayName) == ["C", "G", "Am", "F"])

        // Partial flag propagation
        let partialTimeline = ChordTimelineAnalyzer.analyzePCMBuffer(
            Array(fullBuffer.prefix(Int(sampleRate * 8.0))),
            sampleRate: sampleRate,
            trackId: "rust_ffi_partial_test",
            simpleMode: true,
            knownDuration: 8.0,
            isPartial: true
        )
        #expect(partialTimeline.isPartial == true)
        #expect(!partialTimeline.beats.isEmpty)

        // Backward-compatible decoding of legacy cached JSON without beats/beatsPerBar/sections/isPartial
        let legacyJSON = """
        {
          "trackId": "legacy_1",
          "key": "C Major",
          "bpm": 120.0,
          "simpleMode": true,
          "duration": 8.0,
          "segments": [],
          "analyzedAt": "2025-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLegacy = try decoder.decode(TrackChordTimeline.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.trackId == "legacy_1")
        #expect(decodedLegacy.beats.isEmpty)
        #expect(decodedLegacy.beatsPerBar == 4)
        #expect(decodedLegacy.sections.isEmpty)
        #expect(decodedLegacy.isPartial == false)
    }

    @Test("Live Rust ChordDetector tracks C, Am, G7 transitions and silence gate continuously")
    func testLiveRustChordDetectorContinuousSession() throws {
        let detector = ChordDetector()

        // 1. C Major
        let cBuf = Self.synthesizeChordBuffer(midiNotes: [48, 55, 60, 64, 67])
        let cSnap = Self.feedAndStabilize(detector: detector, samples: cBuf, simpleMode: true, frames: 6, startTime: 0.0)
        #expect(cSnap.chord?.displayName == "C")
        #expect(!cSnap.isSilent)

        // 2. Transition directly to A Minor without reset
        let amBuf = Self.synthesizeChordBuffer(midiNotes: [45, 52, 57, 60, 64])
        let amSnap = Self.feedAndStabilize(detector: detector, samples: amBuf, simpleMode: true, frames: 8, startTime: 1.0)
        #expect(amSnap.chord?.displayName == "Am")

        // 3. Reset & detect G7 in extended mode
        detector.reset()
        let g7Buf = Self.synthesizeChordBuffer(midiNotes: [43, 59, 62, 65, 67])
        let g7Snap = Self.feedAndStabilize(detector: detector, samples: g7Buf, simpleMode: false, frames: 6, startTime: 2.0)
        #expect(g7Snap.chord?.displayName == "G7")

        // 4. Silence gate clears active chord
        let silence = Array(repeating: Float(0), count: 22_050)
        var silentSnap = g7Snap
        for i in 0..<6 {
            silence.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    detector.ingest(samples: base, count: silence.count, sampleRate: 44_100)
                }
            }
            silentSnap = detector.analyze(currentTime: 3.0 + Double(i) * 0.125, simpleMode: false)
        }
        #expect(silentSnap.isSilent == true)
        #expect(silentSnap.chord == nil)
        #expect(silentSnap.rms < 0.001)
    }
}

// MARK: - 8. PlaylistImporter URL Detection, Offline Parsers & Matching Tests

private actor StubImporterInnerTube: InnerTubeServiceProtocol {
    private(set) var lastFetchedPlaylistId: String?
    private(set) var searchQueries: [String] = []
    private var currentConcurrentSearches = 0
    private(set) var maxConcurrentSearches = 0
    private let searchDelayNs: UInt64
    private let playlistTracks: [Track]
    private let searchTracksByQuery: [String: [Track]]

    init(
        playlistTracks: [Track] = [],
        searchDelayNs: UInt64 = 0,
        searchTracksByQuery: [String: [Track]] = [:]
    ) {
        self.playlistTracks = playlistTracks
        self.searchDelayNs = searchDelayNs
        self.searchTracksByQuery = searchTracksByQuery
    }

    func fetchHome() async throws -> [ShelfSection] { [] }
    func fetchExplore() async throws -> [ShelfSection] { [] }
    func fetchSearchSuggestions(query: String) async throws -> [SearchSuggestion] { [] }
    func fetchAlbum(browseId: String) async throws -> Album {
        Album(id: browseId, title: "Album", artist: "Artist")
    }
    func fetchArtist(browseId: String) async throws -> Artist {
        Artist(id: browseId, name: "Artist")
    }
    func fetchUpNextRadio(videoId: String) async throws -> [Track] { [] }
    func setCookie(_ cookie: String?) async {}

    func fetchPlaylist(browseId: String) async throws -> Playlist {
        lastFetchedPlaylistId = browseId
        return Playlist(
            id: browseId,
            title: "Mock YT Playlist",
            author: "Mock Creator",
            artworkURL: playlistTracks.first?.artworkURL,
            tracks: playlistTracks
        )
    }

    func search(query: String) async throws -> SearchResults {
        searchQueries.append(query)
        currentConcurrentSearches += 1
        if currentConcurrentSearches > maxConcurrentSearches {
            maxConcurrentSearches = currentConcurrentSearches
        }
        let delay = searchDelayNs
        let directHits = searchTracksByQuery[query] ?? searchTracksByQuery.first(where: { query.localizedCaseInsensitiveContains($0.key) })?.value ?? []

        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }

        currentConcurrentSearches -= 1
        return SearchResults(query: query, topResult: directHits.first.map { .track($0) }, songs: directHits)
    }
}

@Suite("PlaylistImporter URL Detection, Parsers & Matching")
struct PlaylistImporterTests {

    @Test("Platform URL detection covers all 8 ImportPlatform cases and rejects unknown links")
    func testPlatformDetection() {
        #expect(PlaylistImporter.detectPlatform(from: "https://music.youtube.com/playlist?list=PL123") == .youtubeMusic)
        #expect(PlaylistImporter.detectPlatform(from: "https://www.youtube.com/playlist?list=PL456") == .youtube)
        #expect(PlaylistImporter.detectPlatform(from: "https://youtu.be/dQw4w9WgXcQ?list=PL789") == .youtube)
        #expect(PlaylistImporter.detectPlatform(from: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M") == .spotify)
        #expect(PlaylistImporter.detectPlatform(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M") == .spotify)
        #expect(PlaylistImporter.detectPlatform(from: "https://music.apple.com/us/playlist/favorites/pl.12345") == .appleMusic)
        #expect(PlaylistImporter.detectPlatform(from: "https://www.deezer.com/en/playlist/908622995") == .deezer)
        #expect(PlaylistImporter.detectPlatform(from: "https://soundcloud.com/artist/sets/chill-mix") == .soundcloud)
        #expect(PlaylistImporter.detectPlatform(from: "https://tidal.com/browse/playlist/abc-123") == .tidal)
        #expect(PlaylistImporter.detectPlatform(from: "https://listen.tidal.com/album/987654") == .tidal)
        #expect(PlaylistImporter.detectPlatform(from: "/Users/test/music/mix.m3u") == .localFile)
        #expect(PlaylistImporter.detectPlatform(from: "~/Downloads/export.csv") == .localFile)
        #expect(PlaylistImporter.detectPlatform(from: "file:///tmp/list.m3u8") == .localFile)
        #expect(PlaylistImporter.detectPlatform(from: "https://example.com/playlist/123") == nil)
        #expect(PlaylistImporter.detectPlatform(from: "   ") == nil)
    }

    @Test("Offline parsers decode Spotify, Apple Music, Deezer, SoundCloud, Tidal, M3U, and CSV")
    func testAllOfflinePlaylistParsers() throws {
        // 1. Spotify Embed __NEXT_DATA__
        let spotifyHTML = """
        <html>
        <head><meta property="og:title" content="Coding Focus | Spotify"></head>
        <body>
        <script id="__NEXT_DATA__" type="application/json">
        {
          "props": {
            "pageProps": {
              "state": {
                "data": {
                  "entity": {
                    "name": "Coding Focus",
                    "subtitle": "SoundChord Curated",
                    "coverArt": { "sources": [{"url": "https://i.scdn.co/image/cover300.jpg", "width": 300}] },
                    "trackList": [
                      {"uid": "sp1", "title": "Let Down", "subtitle": "Radiohead", "duration": 299000},
                      {"uid": "sp2", "title": "Midnight City", "subtitle": "M83", "duration": 243000}
                    ]
                  }
                }
              }
            }
          }
        }
        </script>
        </body>
        </html>
        """
        let spotify = try PlaylistImporter.parseSpotifyEmbedHTML(spotifyHTML, sourceURL: "https://open.spotify.com/playlist/abc")
        #expect(spotify.platform == .spotify)
        #expect(spotify.title == "Coding Focus")
        #expect(spotify.author == "SoundChord Curated")
        #expect(spotify.artworkURL?.absoluteString == "https://i.scdn.co/image/cover300.jpg")
        #expect(spotify.candidates.count == 2)
        #expect(spotify.candidates[0].sourceTitle == "Let Down")
        #expect(spotify.candidates[0].sourceArtist == "Radiohead")
        #expect(abs(spotify.candidates[0].sourceDuration - 299.0) < 0.01)

        // 2. Apple Music JSON-LD
        let appleHTML = """
        <html>
        <head>
        <script type="application/ld+json">
        {
          "@type": "MusicPlaylist",
          "name": "Acoustic Mornings",
          "author": {"@type": "Person", "name": "Apple Editorial"},
          "image": "https://is1-ssl.mzstatic.com/image/cover.jpg",
          "track": [
            {
              "@type": "MusicRecording",
              "name": "Blackbird",
              "byArtist": {"name": "The Beatles"},
              "inAlbum": {"name": "The White Album"},
              "duration": "PT2M18S"
            }
          ]
        }
        </script>
        </head>
        </html>
        """
        let apple = try PlaylistImporter.parseAppleMusicHTML(appleHTML, sourceURL: "https://music.apple.com/us/playlist/acoustic/pl.1")
        #expect(apple.platform == .appleMusic)
        #expect(apple.title == "Acoustic Mornings")
        #expect(apple.author == "Apple Editorial")
        #expect(apple.candidates.count == 1)
        #expect(apple.candidates[0].sourceTitle == "Blackbird")
        #expect(apple.candidates[0].sourceArtist == "The Beatles")
        #expect(apple.candidates[0].sourceAlbum == "The White Album")
        #expect(abs(apple.candidates[0].sourceDuration - 138.0) < 0.01)

        // 3. Deezer API JSON
        let deezerJSON = """
        {
          "title": "French Touch Classics",
          "creator": {"name": "Deezer User"},
          "picture_xl": "https://e-cdns-images.dzcdn.net/images/playlist/cover_xl.jpg",
          "tracks": {
            "data": [
              {
                "id": 1001,
                "title": "Digital Love",
                "duration": 301,
                "artist": {"name": "Daft Punk"},
                "album": {"title": "Discovery"}
              }
            ]
          }
        }
        """
        let deezer = try PlaylistImporter.parseDeezerJSON(deezerJSON, sourceURL: "https://www.deezer.com/playlist/123")
        #expect(deezer.platform == .deezer)
        #expect(deezer.title == "French Touch Classics")
        #expect(deezer.author == "Deezer User")
        #expect(deezer.candidates.count == 1)
        #expect(deezer.candidates[0].sourceTitle == "Digital Love")
        #expect(deezer.candidates[0].sourceArtist == "Daft Punk")
        #expect(deezer.candidates[0].sourceAlbum == "Discovery")
        #expect(abs(deezer.candidates[0].sourceDuration - 301.0) < 0.01)

        // 4. SoundCloud __sc_hydration HTML
        let soundcloudHTML = """
        <html><body>
        <script>
        window.__sc_hydration = [
          {"hydratable": "sound", "data": {"id": 55, "title": "Nightcall", "duration": 258000, "user": {"username": "Kavinsky"}}},
          {"hydratable": "playlist", "data": {"title": "Synthwave Drive", "user": {"username": "SynthCurator"}, "artwork_url": "https://i1.sndcdn.com/art-large.jpg", "tracks": [{"id": 55}]}}
        ];
        </script>
        </body></html>
        """
        let sc = try PlaylistImporter.parseSoundCloudHTML(soundcloudHTML, sourceURL: "https://soundcloud.com/synth/sets/drive")
        #expect(sc.platform == .soundcloud)
        #expect(sc.title == "Synthwave Drive")
        #expect(sc.author == "SynthCurator")
        #expect(sc.candidates.count == 1)
        #expect(sc.candidates[0].sourceTitle == "Nightcall")
        #expect(sc.candidates[0].sourceArtist == "Kavinsky")
        #expect(abs(sc.candidates[0].sourceDuration - 258.0) < 0.01)

        // 5. Tidal HTML (JSON-LD success + gated fallback)
        let tidalHTML = """
        <html><head>
        <script type="application/ld+json">
        {
          "@type": "MusicPlaylist",
          "name": "HiFi Test",
          "track": [{"@type": "MusicRecording", "name": "Teardrop", "byArtist": {"name": "Massive Attack"}, "duration": "PT5M30S"}]
        }
        </script>
        </head></html>
        """
        let tidal = try PlaylistImporter.parseTidalHTML(tidalHTML, sourceURL: "https://tidal.com/browse/playlist/abc")
        #expect(tidal.platform == .tidal)
        #expect(tidal.candidates.count == 1)
        #expect(tidal.candidates[0].sourceTitle == "Teardrop")

        do {
            _ = try PlaylistImporter.parseTidalHTML("<html><title>Just a moment...</title></html>")
            Issue.record("Expected Tidal gate page to throw gatedPlatform")
        } catch let err as PlaylistImportError {
            if case .gatedPlatform = err {
                // Expected
            } else {
                Issue.record("Unexpected PlaylistImportError: \(err)")
            }
        }

        // 6. M3U Content
        let m3u = """
        #EXTM3U
        #PLAYLIST:Road Trip Mix
        #EXTINF:238,Radiohead - Creep
        /Music/Radiohead/Creep.flac
        /Music/02 - Daft Punk - Veridis Quo.m4a
        """
        let m3uPreview = try PlaylistImporter.parseM3UContent(m3u, sourceURL: "file:///tmp/roadtrip.m3u")
        #expect(m3uPreview.platform == .localFile)
        #expect(m3uPreview.title == "Road Trip Mix")
        #expect(m3uPreview.candidates.count == 2)
        #expect(m3uPreview.candidates[0].sourceArtist == "Radiohead")
        #expect(m3uPreview.candidates[0].sourceTitle == "Creep")
        #expect(abs(m3uPreview.candidates[0].sourceDuration - 238.0) < 0.01)
        #expect(m3uPreview.candidates[1].sourceArtist == "Daft Punk")
        #expect(m3uPreview.candidates[1].sourceTitle == "Veridis Quo")

        // 7. CSV Content (Exportify format with UTF-8 BOM and quoted commas)
        let csv = "\u{FEFF}\"Track Name\",\"Artist Name(s)\",\"Album Name\",\"Duration (ms)\"\n\"Hello, Goodbye\",\"The Beatles\",\"Magical Mystery Tour\",208000\n"
        let csvPreview = try PlaylistImporter.parseCSVContent(csv, sourceURL: "file:///tmp/export.csv", defaultTitle: "Exported CSV")
        #expect(csvPreview.platform == .localFile)
        #expect(csvPreview.title == "Exported CSV")
        #expect(csvPreview.candidates.count == 1)
        #expect(csvPreview.candidates[0].sourceTitle == "Hello, Goodbye")
        #expect(csvPreview.candidates[0].sourceArtist == "The Beatles")
        #expect(csvPreview.candidates[0].sourceAlbum == "Magical Mystery Tour")
        #expect(abs(csvPreview.candidates[0].sourceDuration - 208.0) < 0.01)
    }

    @Test("YouTube list ID extraction pre-matches tracks and concurrent matching caps concurrency <= 4")
    func testYouTubeListExtractionAndBoundedMatching() async throws {
        let importer = PlaylistImporter()
        let ytTrack1 = makeSampleTrack(id: "yt1", title: "Let Down", artist: "Radiohead", duration: 299)
        let ytTrack2 = makeSampleTrack(id: "yt2", title: "No Surprises", artist: "Radiohead", duration: 229)
        let ytStub = StubImporterInnerTube(playlistTracks: [ytTrack1, ytTrack2])

        let ytPreview = try await importer.extractPlaylist(
            from: "https://music.youtube.com/playlist?list=PL_SOUNDCHORD_99&si=shareToken",
            innerTube: ytStub
        )
        #expect(await ytStub.lastFetchedPlaylistId == "PL_SOUNDCHORD_99")
        #expect(ytPreview.platform == .youtubeMusic)
        #expect(ytPreview.candidates.count == 2)
        #expect(ytPreview.candidates.allSatisfy { $0.status == .matched && $0.isSelected && $0.matchScore == 1.0 })

        // Verify bounded <= 4 concurrency in matchCandidates
        var searchMap: [String: [Track]] = [:]
        var pendingCandidates: [ImportedTrackCandidate] = []
        for idx in 1...10 {
            let title = "Track \(idx)"
            let track = makeSampleTrack(id: "m_\(idx)", title: title, artist: "Artist \(idx)", duration: 200)
            searchMap["\(title) Artist \(idx)"] = [track]
            pendingCandidates.append(
                ImportedTrackCandidate(
                    id: "c_\(idx)",
                    sourceTitle: title,
                    sourceArtist: "Artist \(idx)",
                    sourceDuration: 200,
                    status: .pending
                )
            )
        }

        let matchStub = StubImporterInnerTube(
            searchDelayNs: 15_000_000, // 15 ms
            searchTracksByQuery: searchMap
        )

        let inputPreview = ImportedPlaylistPreview(
            platform: .spotify,
            title: "Concurrency Test",
            sourceURL: "https://open.spotify.com/playlist/concurrency",
            candidates: pendingCandidates
        )

        let matched = await importer.matchCandidates(inputPreview, innerTube: matchStub) { _, _ in }
        let maxObserved = await matchStub.maxConcurrentSearches
        #expect(matched.candidates.count == 10)
        #expect(matched.candidates.allSatisfy { $0.status == .matched && $0.matchedTrack != nil && $0.isSelected })
        #expect(maxObserved >= 1 && maxObserved <= 4)
    }
}

// MARK: - 9. BitChord -> SoundChord Automatic Storage Migration Tests

@Suite("BitChord to SoundChord Storage Migration", .serialized)
@MainActor
struct BitChordStorageMigrationTests {

    private func makeIsolatedTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundChordMigrationHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("LibraryStore and AddonManager automatically migrate BitChord storage to SoundChord in isolated temp homes")
    func testAutomaticLegacyStorageMigration() throws {
        let fm = FileManager.default
        let previousCFHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        defer {
            if let previousCFHome {
                setenv("CFFIXED_USER_HOME", previousCFHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
        }

        // 1. Seed and verify LibraryStore migration (BitChord/bitchord.sqlite -> SoundChord/soundchord.sqlite)
        let tempHome1 = try makeIsolatedTempHome()
        defer { try? fm.removeItem(at: tempHome1) }

        let stagingDir = tempHome1.appendingPathComponent("staging_legacy", isDirectory: true)
        let sampleTrack = makeSampleTrack(id: "mig_track_1", title: "Subterranean Homesick Alien", artist: "Radiohead", duration: 267)
        let sampleTimeline = TrackChordTimeline(
            trackId: "mig_track_1",
            key: "C Major",
            bpm: 112.0,
            simpleMode: true,
            duration: 12.0,
            segments: [
                TimedChordSegment(chord: DetectedChord(root: 0, quality: .major, confidence: 0.94, timestamp: 0), startTime: 0, endTime: 6.0)
            ]
        )

        do {
            let stagingStore = LibraryStore(baseDirectory: stagingDir)
            stagingStore.toggleLike(sampleTrack)
            let pl = stagingStore.createPlaylist(title: "Legacy BitChord Mix", description: "Migrated")
            stagingStore.addToPlaylist(playlistId: pl.id, track: sampleTrack)
            var s = stagingStore.settings
            s.crossfadeSeconds = 7.5
            stagingStore.saveSettings(s)
            stagingStore.saveChordTimeline(sampleTimeline)
        }

        let appSupport1 = tempHome1.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacyRoot1 = appSupport1.appendingPathComponent("BitChord", isDirectory: true)
        let newRoot1 = appSupport1.appendingPathComponent("SoundChord", isDirectory: true)
        try fm.createDirectory(at: legacyRoot1, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let src = stagingDir.appendingPathComponent("soundchord.sqlite\(suffix)")
            let dst = legacyRoot1.appendingPathComponent("bitchord.sqlite\(suffix)")
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dst)
            }
        }

        #expect(!fm.fileExists(atPath: newRoot1.path))

        setenv("CFFIXED_USER_HOME", tempHome1.path, 1)
        let migratedStore = LibraryStore()
        unsetenv("CFFIXED_USER_HOME")

        #expect(fm.fileExists(atPath: newRoot1.appendingPathComponent("soundchord.sqlite").path))
        #expect(!fm.fileExists(atPath: newRoot1.appendingPathComponent("bitchord.sqlite").path))
        #expect(migratedStore.isLiked("mig_track_1"))
        #expect(migratedStore.playlists.first?.title == "Legacy BitChord Mix")
        #expect(migratedStore.playlists.first?.tracks.map(\.id) == ["mig_track_1"])
        #expect(migratedStore.settings.crossfadeSeconds == 7.5)
        let migratedTimeline = try #require(migratedStore.loadChordTimeline(trackId: "mig_track_1"))
        #expect(migratedTimeline.key == "C Major")
        #expect(migratedTimeline.segments.first?.chord.displayName == "C")

        // 2. Seed and verify AddonManager migration (BitChord/addons.json -> SoundChord/addons.json)
        let tempHome2 = try makeIsolatedTempHome()
        defer { try? fm.removeItem(at: tempHome2) }

        let appSupport2 = tempHome2.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacyRoot2 = appSupport2.appendingPathComponent("BitChord", isDirectory: true)
        let newRoot2 = appSupport2.appendingPathComponent("SoundChord", isDirectory: true)
        try fm.createDirectory(at: legacyRoot2, withIntermediateDirectories: true)

        let legacyAddons = [
            AddonConfig(
                id: "legacy-res",
                name: "Legacy Resonance",
                baseURL: "https://www.resonance.web.id",
                isEnabled: true,
                preferredQuality: "lossless"
            )
        ]
        let addonData = try JSONEncoder().encode(legacyAddons)
        try addonData.write(to: legacyRoot2.appendingPathComponent("addons.json"))

        #expect(!fm.fileExists(atPath: newRoot2.appendingPathComponent("addons.json").path))

        setenv("CFFIXED_USER_HOME", tempHome2.path, 1)
        let migratedAddons = AddonManager()
        unsetenv("CFFIXED_USER_HOME")

        #expect(fm.fileExists(atPath: newRoot2.appendingPathComponent("addons.json").path))
        #expect(migratedAddons.addons.count == 1)
        #expect(migratedAddons.addons.first?.id == "legacy-res")
        #expect(migratedAddons.addons.first?.name == "Legacy Resonance")
    }
}
