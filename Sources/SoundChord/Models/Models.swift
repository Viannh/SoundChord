import Foundation

// MARK: - Track

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let videoId: String
    public var title: String
    public var artist: String
    public var artistId: String?
    public var album: String?
    public var albumId: String?
    public var duration: TimeInterval
    public var artworkURL: URL?
    public var localFileURL: URL?
    public var isDownloaded: Bool
    public var isLocal: Bool
    public var qualityLabel: String?
    public var audioCodec: String?
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var bitDepth: Int?
    public var isExplicit: Bool
    public var addonConfigId: String?
    public var addonTrackId: String?
    public var sourceName: String?

    public init(
        id: String? = nil,
        videoId: String,
        title: String,
        artist: String,
        artistId: String? = nil,
        album: String? = nil,
        albumId: String? = nil,
        duration: TimeInterval = 0,
        artworkURL: URL? = nil,
        localFileURL: URL? = nil,
        isDownloaded: Bool = false,
        isLocal: Bool = false,
        qualityLabel: String? = nil,
        audioCodec: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        isExplicit: Bool = false,
        addonConfigId: String? = nil,
        addonTrackId: String? = nil,
        sourceName: String? = nil
    ) {
        self.id = id ?? videoId
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.duration = duration
        self.artworkURL = artworkURL
        self.localFileURL = localFileURL
        self.isDownloaded = isDownloaded
        self.isLocal = isLocal
        self.qualityLabel = qualityLabel
        self.audioCodec = audioCodec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.isExplicit = isExplicit
        self.addonConfigId = addonConfigId
        self.addonTrackId = addonTrackId
        self.sourceName = sourceName
    }

    public var formattedDuration: String {
        Self.formatTime(duration)
    }

    public var highResArtworkURL: URL? {
        guard let artworkURL else { return nil }
        return Self.upscaledArtworkURL(artworkURL, size: 544)
    }

    public var isPlayableOffline: Bool {
        if let localFileURL {
            return FileManager.default.fileExists(atPath: localFileURL.path)
        }
        return false
    }

    public static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func upscaledArtworkURL(_ url: URL, size: Int = 544) -> URL {
        let raw = url.absoluteString
        if raw.contains("lh3.googleusercontent.com") || raw.contains("yt3.ggpht.com") {
            let pattern = #"=w\d+-h\d+[^&\s]*"#
            if let range = raw.range(of: pattern, options: .regularExpression) {
                var upgraded = raw
                upgraded.replaceSubrange(range, with: "=w\(size)-h\(size)-l90-rj")
                if let result = URL(string: upgraded) {
                    return result
                }
            }
        }
        return url
    }
}

// MARK: - Album, Artist, Playlist

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var artistId: String?
    public var year: String?
    public var artworkURL: URL?
    public var description: String?
    public var tracks: [Track]
    public var isExplicit: Bool
    public var playlistId: String?

    public init(
        id: String,
        title: String,
        artist: String,
        artistId: String? = nil,
        year: String? = nil,
        artworkURL: URL? = nil,
        description: String? = nil,
        tracks: [Track] = [],
        isExplicit: Bool = false,
        playlistId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.year = year
        self.artworkURL = artworkURL
        self.description = description
        self.tracks = tracks
        self.isExplicit = isExplicit
        self.playlistId = playlistId
    }

    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}

public struct Artist: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var subscriberCount: String?
    public var artworkURL: URL?
    public var bannerURL: URL?
    public var topSongs: [Track]
    public var albums: [Album]
    public var singles: [Album]
    public var relatedArtists: [Artist]
    public var shufflePlaylistId: String?
    public var radioPlaylistId: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        subscriberCount: String? = nil,
        artworkURL: URL? = nil,
        bannerURL: URL? = nil,
        topSongs: [Track] = [],
        albums: [Album] = [],
        singles: [Album] = [],
        relatedArtists: [Artist] = [],
        shufflePlaylistId: String? = nil,
        radioPlaylistId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.subscriberCount = subscriberCount
        self.artworkURL = artworkURL
        self.bannerURL = bannerURL
        self.topSongs = topSongs
        self.albums = albums
        self.singles = singles
        self.relatedArtists = relatedArtists
        self.shufflePlaylistId = shufflePlaylistId
        self.radioPlaylistId = radioPlaylistId
    }
}

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: URL?
    public var tracks: [Track]
    public var isUserCreated: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        author: String? = nil,
        description: String? = nil,
        artworkURL: URL? = nil,
        tracks: [Track] = [],
        isUserCreated: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.artworkURL = artworkURL
        self.tracks = tracks
        self.isUserCreated = isUserCreated
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}

// MARK: - Shelves & Discovery

public enum ShelfStyle: String, Codable, Hashable, Sendable {
    case squareGrid
    case trackList
    case hero
    case artists
    case moodChips
}

public enum ShelfItem: Codable, Identifiable, Hashable, Sendable {
    case track(Track)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .track(let t): return "track:\(t.id)"
        case .album(let a): return "album:\(a.id)"
        case .artist(let a): return "artist:\(a.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        }
    }

    public var title: String {
        switch self {
        case .track(let t): return t.title
        case .album(let a): return a.title
        case .artist(let a): return a.name
        case .playlist(let p): return p.title
        }
    }

    public var subtitle: String {
        switch self {
        case .track(let t): return t.artist
        case .album(let a): return [a.artist, a.year].compactMap { $0 }.joined(separator: " • ")
        case .artist(let a): return a.subscriberCount ?? "Artist"
        case .playlist(let p): return p.author ?? "Playlist"
        }
    }

    public var artworkURL: URL? {
        switch self {
        case .track(let t): return t.artworkURL
        case .album(let a): return a.artworkURL
        case .artist(let a): return a.artworkURL
        case .playlist(let p): return p.artworkURL ?? p.tracks.first?.artworkURL
        }
    }

    public var kindLabel: String {
        switch self {
        case .track: return "Song"
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        }
    }
}

public struct ShelfSection: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var style: ShelfStyle
    public var items: [ShelfItem]
    public var browseId: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        style: ShelfStyle = .squareGrid,
        items: [ShelfItem],
        browseId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.items = items
        self.browseId = browseId
    }
}

// MARK: - Search

public struct SearchResults: Codable, Hashable, Sendable {
    public var query: String
    public var topResult: ShelfItem?
    public var songs: [Track]
    public var albums: [Album]
    public var artists: [Artist]
    public var playlists: [Playlist]

    public init(
        query: String = "",
        topResult: ShelfItem? = nil,
        songs: [Track] = [],
        albums: [Album] = [],
        artists: [Artist] = [],
        playlists: [Playlist] = []
    ) {
        self.query = query
        self.topResult = topResult
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        topResult == nil && songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }
}

public struct SearchSuggestion: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var text: String
    public var item: ShelfItem?

    public init(id: String = UUID().uuidString, text: String, item: ShelfItem? = nil) {
        self.id = id
        self.text = text
        self.item = item
    }
}

// MARK: - Resolved Stream

public struct ResolvedStream: Codable, Hashable, Sendable {
    public var url: URL
    public var mimeType: String
    public var codec: String
    public var bitrateKbps: Int
    public var sampleRateHz: Int?
    public var bitDepth: Int?
    public var contentLength: Int64?
    public var expiresAt: Date
    public var clientName: String
    public var qualityLabel: String
    public var isHLS: Bool
    public var requestHeaders: [String: String]
    public var durationSeconds: TimeInterval?

    public init(
        url: URL,
        mimeType: String,
        codec: String,
        bitrateKbps: Int,
        sampleRateHz: Int? = 44100,
        bitDepth: Int? = 16,
        contentLength: Int64? = nil,
        expiresAt: Date = Date().addingTimeInterval(3600 * 5),
        clientName: String,
        qualityLabel: String,
        isHLS: Bool = false,
        requestHeaders: [String: String] = [:],
        durationSeconds: TimeInterval? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.contentLength = contentLength
        self.expiresAt = expiresAt
        self.clientName = clientName
        self.qualityLabel = qualityLabel
        self.isHLS = isHLS
        self.requestHeaders = requestHeaders
        self.durationSeconds = durationSeconds
    }

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }

    public var formattedSummary: String {
        var parts: [String] = [qualityLabel, codec.uppercased()]
        if bitrateKbps > 0 { parts.append("\(bitrateKbps) kbps") }
        if let bitDepth, bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        if let sampleRateHz, sampleRateHz > 0 {
            let khz = Double(sampleRateHz) / 1000.0
            parts.append(String(format: "%.1f kHz", khz))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Synced Lyrics

public struct LyricWord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        id: String = UUID().uuidString,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct LyricLine: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var words: [LyricWord]
    public var isBackgroundVocal: Bool
    public var translatedText: String?

    public init(
        id: String = UUID().uuidString,
        startTime: TimeInterval,
        endTime: TimeInterval = 0,
        text: String,
        words: [LyricWord] = [],
        isBackgroundVocal: Bool = false,
        translatedText: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
        self.isBackgroundVocal = isBackgroundVocal
        self.translatedText = translatedText
    }

    public var isWordSynced: Bool {
        !words.isEmpty
    }
}

public struct LyricsDocument: Codable, Hashable, Sendable {
    public var trackId: String
    public var provider: String
    public var isSynced: Bool
    public var isWordSynced: Bool
    public var lines: [LyricLine]
    public var plainText: String

    public init(
        trackId: String = "",
        provider: String,
        isSynced: Bool,
        isWordSynced: Bool = false,
        lines: [LyricLine],
        plainText: String? = nil
    ) {
        self.trackId = trackId
        self.provider = provider
        self.isSynced = isSynced
        self.isWordSynced = isWordSynced || lines.contains(where: { $0.isWordSynced })
        self.lines = lines
        self.plainText = plainText ?? lines.map(\.text).joined(separator: "\n")
    }
}

// MARK: - Audio Quality, Repeat, Theme

public enum AudioQuality: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case low
    case medium
    case high
    case lossless

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }

    public var detail: String {
        switch self {
        case .low: return "Up to 64 kbps AAC/Opus"
        case .medium: return "Up to 128 kbps AAC/Opus"
        case .high: return "Best AAC / Opus (up to 256 kbps)"
        case .lossless: return "Best available (ALAC/FLAC or Hi-Res AAC)"
        }
    }

    public var maxBitrateKbps: Int {
        switch self {
        case .low: return 64
        case .medium: return 128
        case .high: return 256
        case .lossless: return Int.max
        }
    }
}

public enum RepeatMode: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case all
    case one

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }
}

public enum ThemeMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

// MARK: - Equalizer (7-band, 16 presets)

public struct EQBand: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let frequencyHz: Float
    public let label: String
    public var gainDb: Float

    public init(id: Int, frequencyHz: Float, label: String, gainDb: Float = 0) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.label = label
        self.gainDb = max(-12, min(12, gainDb))
    }

    public static let defaultFrequencies: [Float] = [60, 150, 400, 1_000, 2_400, 6_000, 15_000]
    public static let defaultLabels: [String] = ["60Hz", "150Hz", "400Hz", "1kHz", "2.4kHz", "6kHz", "15kHz"]

    public static func bands(from gains: [Float]) -> [EQBand] {
        defaultFrequencies.indices.map { idx in
            let gain = idx < gains.count ? gains[idx] : 0
            return EQBand(
                id: idx,
                frequencyHz: defaultFrequencies[idx],
                label: defaultLabels[idx],
                gainDb: gain
            )
        }
    }
}

public enum EQPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case flat
    case bassBoost
    case trebleBoost
    case vocal
    case rock
    case pop
    case jazz
    case classical
    case electronic
    case hipHop
    case rnb
    case acoustic
    case lateNight
    case loudness
    case studio
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .bassBoost: return "Bass Boost"
        case .trebleBoost: return "Treble Boost"
        case .vocal: return "Vocal"
        case .rock: return "Rock"
        case .pop: return "Pop"
        case .jazz: return "Jazz"
        case .classical: return "Classical"
        case .electronic: return "Electronic"
        case .hipHop: return "Hip-Hop"
        case .rnb: return "R&B"
        case .acoustic: return "Acoustic"
        case .lateNight: return "Late Night"
        case .loudness: return "Loudness"
        case .studio: return "Studio"
        case .custom: return "Custom"
        }
    }

    /// 7-band gains in dB corresponding to [60Hz, 150Hz, 400Hz, 1kHz, 2.4kHz, 6kHz, 15kHz].
    public var gains: [Float] {
        switch self {
        case .flat:        return [0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:   return [6, 4, 1.5, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 1.5, 3.5, 5]
        case .vocal:       return [-3, -1.5, 1, 3.5, 3, 1, -1]
        case .rock:        return [4, 2.5, -1, -1.5, 1, 3, 3.5]
        case .pop:         return [-1, 1.5, 3, 2, 0.5, 2, 1.5]
        case .jazz:        return [3, 1.5, 0, 1, 1.5, 2, 2.5]
        case .classical:   return [3, 2, 0, 0, 1, 2.5, 3]
        case .electronic:  return [5, 3, -1, 0, 1, 3, 4]
        case .hipHop:      return [6, 4, 0.5, -1, 0.5, 2, 2.5]
        case .rnb:         return [4.5, 3.5, 1, -0.5, 1.5, 2.5, 2]
        case .acoustic:    return [3, 1.5, 0, 1.5, 2.5, 2, 1]
        case .lateNight:   return [3, 1, 0, 1.5, 1, -1, -3]
        case .loudness:    return [6, 3.5, 0, -1.5, -1, 2, 5]
        case .studio:      return [0.5, 0, -0.5, 0, 0.5, 1, 0.5]
        case .custom:      return [0, 0, 0, 0, 0, 0, 0]
        }
    }

    public static func matching(gains: [Float]) -> EQPreset {
        guard gains.count == EQBand.defaultFrequencies.count else { return .custom }
        for preset in Self.allCases where preset != .custom {
            let match = zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.05 }
            if match { return preset }
        }
        return .custom
    }
}

// MARK: - Listening Stats & Replay

public struct ListeningEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var track: Track
    public var playedAt: Date
    public var durationPlayed: TimeInterval

    public init(
        id: UUID = UUID(),
        track: Track,
        playedAt: Date = Date(),
        durationPlayed: TimeInterval
    ) {
        self.id = id
        self.track = track
        self.playedAt = playedAt
        self.durationPlayed = durationPlayed
    }
}

public struct RankedTrack: Codable, Identifiable, Hashable, Sendable {
    public var id: String { track.id }
    public var track: Track
    public var playCount: Int
    public var totalSeconds: TimeInterval

    public init(track: Track, playCount: Int, totalSeconds: TimeInterval) {
        self.track = track
        self.playCount = playCount
        self.totalSeconds = totalSeconds
    }
}

public struct RankedArtist: Codable, Identifiable, Hashable, Sendable {
    public var id: String { artistId ?? name }
    public var name: String
    public var artistId: String?
    public var artworkURL: URL?
    public var playCount: Int
    public var totalSeconds: TimeInterval

    public init(
        name: String,
        artistId: String? = nil,
        artworkURL: URL? = nil,
        playCount: Int,
        totalSeconds: TimeInterval
    ) {
        self.name = name
        self.artistId = artistId
        self.artworkURL = artworkURL
        self.playCount = playCount
        self.totalSeconds = totalSeconds
    }
}

public struct RankedAlbum: Codable, Identifiable, Hashable, Sendable {
    public var id: String { albumId ?? "\(artist)::\(title)" }
    public var title: String
    public var artist: String
    public var albumId: String?
    public var artworkURL: URL?
    public var playCount: Int

    public init(
        title: String,
        artist: String,
        albumId: String? = nil,
        artworkURL: URL? = nil,
        playCount: Int
    ) {
        self.title = title
        self.artist = artist
        self.albumId = albumId
        self.artworkURL = artworkURL
        self.playCount = playCount
    }
}

public struct ReplaySummary: Codable, Hashable, Sendable {
    public var periodLabel: String
    public var totalMinutes: Int
    public var totalPlays: Int
    public var uniqueTracksCount: Int
    public var uniqueArtistsCount: Int
    public var topTracks: [RankedTrack]
    public var topArtists: [RankedArtist]
    public var topAlbums: [RankedAlbum]
    public var monthlyMinutes: [String: Int]
    public var longestStreakDays: Int
    public var peakListeningHour: Int?

    public init(
        periodLabel: String = "All Time",
        totalMinutes: Int = 0,
        totalPlays: Int = 0,
        uniqueTracksCount: Int = 0,
        uniqueArtistsCount: Int = 0,
        topTracks: [RankedTrack] = [],
        topArtists: [RankedArtist] = [],
        topAlbums: [RankedAlbum] = [],
        monthlyMinutes: [String: Int] = [:],
        longestStreakDays: Int = 0,
        peakListeningHour: Int? = nil
    ) {
        self.periodLabel = periodLabel
        self.totalMinutes = totalMinutes
        self.totalPlays = totalPlays
        self.uniqueTracksCount = uniqueTracksCount
        self.uniqueArtistsCount = uniqueArtistsCount
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.topAlbums = topAlbums
        self.monthlyMinutes = monthlyMinutes
        self.longestStreakDays = longestStreakDays
        self.peakListeningHour = peakListeningHour
    }
}

// MARK: - App Settings

public struct AppSettings: Codable, Hashable, Sendable {
    public var themeMode: ThemeMode
    public var accentColorHex: String
    public var crossfadeSeconds: Double
    public var eqEnabled: Bool
    public var eqPreset: EQPreset
    public var eqGains: [Float]
    public var balance: Float
    public var loudnessNormalization: Bool
    public var playbackSpeed: Float
    public var streamQuality: AudioQuality
    public var downloadQuality: AudioQuality
    public var lyricsProvidersOrder: [String]
    public var lyricsOffsetMs: [String: Double]
    public var discordRPCEnabled: Bool
    public var discordShowButtons: Bool
    public var ytCookieHeader: String
    public var localMusicFolders: [String]
    public var glassOpacity: Double
    public var addonLosslessUpgrade: Bool
    public var addonDurationToleranceSec: Double

    public static let defaultLyricsProviders: [String] = [
        "lrc.red",
        "BiniLyrics",
        "BetterLyrics",
        "LyricsPlus",
        "LRCLIB",
        "KuGou",
        "YouTube Music",
        "Genius"
    ]

    public static let `default` = AppSettings()

    public init(
        themeMode: ThemeMode = .dark,
        accentColorHex: String = "#FA2D48",
        crossfadeSeconds: Double = 0,
        eqEnabled: Bool = false,
        eqPreset: EQPreset = .flat,
        eqGains: [Float] = EQPreset.flat.gains,
        balance: Float = 0,
        loudnessNormalization: Bool = true,
        playbackSpeed: Float = 1.0,
        streamQuality: AudioQuality = .high,
        downloadQuality: AudioQuality = .high,
        lyricsProvidersOrder: [String] = AppSettings.defaultLyricsProviders,
        lyricsOffsetMs: [String: Double] = [:],
        discordRPCEnabled: Bool = true,
        discordShowButtons: Bool = true,
        ytCookieHeader: String = "",
        localMusicFolders: [String] = [],
        glassOpacity: Double = 0.78,
        addonLosslessUpgrade: Bool = true,
        addonDurationToleranceSec: Double = 6.0
    ) {
        self.themeMode = themeMode
        self.accentColorHex = accentColorHex
        self.crossfadeSeconds = max(0, min(12, crossfadeSeconds))
        self.eqEnabled = eqEnabled
        self.eqPreset = eqPreset
        self.eqGains = eqGains.count == EQBand.defaultFrequencies.count ? eqGains : EQPreset.flat.gains
        self.balance = max(-1, min(1, balance))
        self.loudnessNormalization = loudnessNormalization
        self.playbackSpeed = max(0.5, min(2.0, playbackSpeed))
        self.streamQuality = streamQuality
        self.downloadQuality = downloadQuality
        self.lyricsProvidersOrder = lyricsProvidersOrder
        self.lyricsOffsetMs = lyricsOffsetMs
        self.discordRPCEnabled = discordRPCEnabled
        self.discordShowButtons = discordShowButtons
        self.ytCookieHeader = ytCookieHeader
        self.localMusicFolders = localMusicFolders
        self.glassOpacity = max(0.3, min(1.0, glassOpacity))
        self.addonLosslessUpgrade = addonLosslessUpgrade
        self.addonDurationToleranceSec = max(0, min(30, addonDurationToleranceSec))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        self.themeMode = try c.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? d.themeMode
        self.accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? d.accentColorHex
        self.crossfadeSeconds = max(0, min(12, try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? d.crossfadeSeconds))
        self.eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? d.eqEnabled
        self.eqPreset = try c.decodeIfPresent(EQPreset.self, forKey: .eqPreset) ?? d.eqPreset
        let decodedGains = try c.decodeIfPresent([Float].self, forKey: .eqGains) ?? d.eqGains
        self.eqGains = decodedGains.count == EQBand.defaultFrequencies.count ? decodedGains : EQPreset.flat.gains
        self.balance = max(-1, min(1, try c.decodeIfPresent(Float.self, forKey: .balance) ?? d.balance))
        self.loudnessNormalization = try c.decodeIfPresent(Bool.self, forKey: .loudnessNormalization) ?? d.loudnessNormalization
        self.playbackSpeed = max(0.5, min(2.0, try c.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? d.playbackSpeed))
        self.streamQuality = try c.decodeIfPresent(AudioQuality.self, forKey: .streamQuality) ?? d.streamQuality
        self.downloadQuality = try c.decodeIfPresent(AudioQuality.self, forKey: .downloadQuality) ?? d.downloadQuality
        self.lyricsProvidersOrder = try c.decodeIfPresent([String].self, forKey: .lyricsProvidersOrder) ?? d.lyricsProvidersOrder
        self.lyricsOffsetMs = try c.decodeIfPresent([String: Double].self, forKey: .lyricsOffsetMs) ?? d.lyricsOffsetMs
        self.discordRPCEnabled = try c.decodeIfPresent(Bool.self, forKey: .discordRPCEnabled) ?? d.discordRPCEnabled
        self.discordShowButtons = try c.decodeIfPresent(Bool.self, forKey: .discordShowButtons) ?? d.discordShowButtons
        self.ytCookieHeader = try c.decodeIfPresent(String.self, forKey: .ytCookieHeader) ?? d.ytCookieHeader
        self.localMusicFolders = try c.decodeIfPresent([String].self, forKey: .localMusicFolders) ?? d.localMusicFolders
        self.glassOpacity = max(0.3, min(1.0, try c.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? d.glassOpacity))
        self.addonLosslessUpgrade = try c.decodeIfPresent(Bool.self, forKey: .addonLosslessUpgrade) ?? d.addonLosslessUpgrade
        self.addonDurationToleranceSec = max(0, min(30, try c.decodeIfPresent(Double.self, forKey: .addonDurationToleranceSec) ?? d.addonDurationToleranceSec))
    }
}

// MARK: - Navigation & UI Enums

public enum SidebarItem: Hashable, Identifiable, Sendable {
    case home
    case explore
    case search
    case library
    case downloads
    case localMusic
    case addons
    case replay
    case settings
    case playlist(String)

    public var id: String {
        switch self {
        case .home: return "home"
        case .explore: return "explore"
        case .search: return "search"
        case .library: return "library"
        case .downloads: return "downloads"
        case .localMusic: return "localMusic"
        case .addons: return "addons"
        case .replay: return "replay"
        case .settings: return "settings"
        case .playlist(let pid): return "playlist:\(pid)"
        }
    }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .explore: return "Explore"
        case .search: return "Search"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .localMusic: return "Local Music"
        case .addons: return "Addons"
        case .replay: return "Replay"
        case .settings: return "Settings"
        case .playlist: return "Playlist"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .explore: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .library: return "music.note.list"
        case .downloads: return "arrow.down.circle.fill"
        case .localMusic: return "folder.fill"
        case .addons: return "puzzlepiece.extension.fill"
        case .replay: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        case .playlist: return "list.bullet.rectangle.portrait"
        }
    }
}

public enum RightDrawerTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case queue
    case lyrics
    case chords

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queue: return "Up Next"
        case .lyrics: return "Lyrics"
        case .chords: return "Chords"
        }
    }

    public var systemImage: String {
        switch self {
        case .queue: return "list.bullet"
        case .lyrics: return "quote.bubble"
        case .chords: return "guitars"
        }
    }
}

public enum NavigationDestination: Hashable, Sendable {
    case album(Album)
    case albumId(String)
    case artist(Artist)
    case artistId(String)
    case playlist(Playlist)
    case playlistId(String)
    case shelf(ShelfSection)
}

// MARK: - Downloads & Backup

public enum DownloadStatus: String, Codable, Hashable, Sendable {
    case queued
    case downloading
    case completed
    case failed
}

public struct DownloadTaskState: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var track: Track
    public var progress: Double
    public var status: DownloadStatus
    public var error: String?

    public init(
        id: String? = nil,
        track: Track,
        progress: Double = 0,
        status: DownloadStatus = .queued,
        error: String? = nil
    ) {
        self.id = id ?? track.id
        self.track = track
        self.progress = progress
        self.status = status
        self.error = error
    }
}

public struct AppBackupPayload: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var likedTracks: [Track]
    public var playlists: [Playlist]
    public var history: [ListeningEvent]
    public var searchHistory: [String]
    public var settings: AppSettings

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        likedTracks: [Track],
        playlists: [Playlist],
        history: [ListeningEvent],
        searchHistory: [String],
        settings: AppSettings
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.likedTracks = likedTracks
        self.playlists = playlists
        self.history = history
        self.searchHistory = searchHistory
        self.settings = settings
    }
}
