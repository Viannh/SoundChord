import Foundation

// MARK: - Shared Service Errors

public enum BitChordError: LocalizedError, Sendable {
    case invalidURL
    case networkFailure(String)
    case httpError(Int, String)
    case parseError(String)
    case streamUnavailable(String)
    case unauthenticated
    case storageFailure(String)
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid request URL."
        case .networkFailure(let detail):
            return "Network error: \(detail)"
        case .httpError(let code, let detail):
            return "HTTP \(code): \(detail)"
        case .parseError(let detail):
            return "Failed to parse response: \(detail)"
        case .streamUnavailable(let detail):
            return "Audio stream unavailable: \(detail)"
        case .unauthenticated:
            return "Sign in required for this action."
        case .storageFailure(let detail):
            return "Storage error: \(detail)"
        case .translationFailed(let detail):
            return "Lyrics translation failed: \(detail)"
        }
    }
}

// MARK: - InnerTube Service

public protocol InnerTubeServiceProtocol: Sendable {
    func fetchHome() async throws -> [ShelfSection]
    func fetchExplore() async throws -> [ShelfSection]
    func fetchSearchSuggestions(query: String) async throws -> [SearchSuggestion]
    func search(query: String) async throws -> SearchResults
    func fetchAlbum(browseId: String) async throws -> Album
    func fetchArtist(browseId: String) async throws -> Artist
    func fetchPlaylist(browseId: String) async throws -> Playlist
    func fetchUpNextRadio(videoId: String) async throws -> [Track]
    func setCookie(_ cookie: String?) async
}

// MARK: - Stream Resolver Service

public protocol StreamResolverProtocol: Sendable {
    func resolveStream(videoId: String, quality: AudioQuality) async throws -> ResolvedStream
    func invalidate(videoId: String) async
    func clearCache() async
}

public extension StreamResolverProtocol {
    func invalidate(videoId: String) async {}
}

// MARK: - Synced Lyrics Service

public protocol LyricsServiceProtocol: Sendable {
    func fetchLyrics(track: Track, providerOrder: [String]) async -> LyricsDocument?
    func translateLyrics(document: LyricsDocument, targetLang: String) async throws -> LyricsDocument
}

// MARK: - Audio Player Service

@MainActor
public protocol AudioPlayerProtocol: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var currentTrack: Track? { get }
    var queue: [Track] { get }
    var currentIndex: Int { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var volume: Float { get }
    var isMuted: Bool { get }
    var isShuffled: Bool { get }
    var repeatMode: RepeatMode { get }
    var playbackRate: Float { get }
    var crossfadeSeconds: Double { get }
    var eqEnabled: Bool { get }
    var eqGains: [Float] { get }
    var balance: Float { get }
    var loudnessNormalization: Bool { get }
    var sleepTimerRemaining: TimeInterval? { get }
    var currentStreamInfo: ResolvedStream? { get }
    var lastError: String? { get }

    var onTrackChanged: ((Track, ResolvedStream?) -> Void)? { get set }
    var onPlaybackStateChanged: ((Bool, TimeInterval, TimeInterval) -> Void)? { get set }
    var onTrackEnded: ((Track, TimeInterval) -> Void)? { get set }
    var onNeedRadioTracks: ((Track) async -> [Track])? { get set }

    func play(track: Track, queue: [Track]?) async
    func togglePlayPause()
    func pause()
    func resume()
    func next() async
    func previous() async
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Float)
    func toggleMute()
    func toggleShuffle()
    func cycleRepeatMode()
    func setPlaybackRate(_ rate: Float)
    func applyEQ(enabled: Bool, gains: [Float], balance: Float)
    func setLoudnessNormalization(_ enabled: Bool)
    func setCrossfade(_ seconds: Double)
    func setStreamQuality(_ quality: AudioQuality)
    func setSleepTimer(minutes: Int?)
    func reorderQueue(from source: IndexSet, to destination: Int)
    func removeFromQueue(at index: Int)
    func addToQueue(_ track: Track, playNext: Bool)
    func clearQueue()
}

// MARK: - Library & Persistence Service

@MainActor
public protocol LibraryStoreProtocol: AnyObject {
    var likedTracks: [Track] { get }
    var playlists: [Playlist] { get }
    var history: [ListeningEvent] { get }
    var downloads: [Track] { get }
    var activeDownloads: [String: DownloadTaskState] { get }
    var localTracks: [Track] { get }
    var settings: AppSettings { get }
    var searchHistory: [String] { get }

    func isLiked(_ trackId: String) -> Bool
    func toggleLike(_ track: Track)
    @discardableResult
    func createPlaylist(title: String, description: String?) -> Playlist
    func deletePlaylist(id: String)
    func renamePlaylist(id: String, title: String)
    func addToPlaylist(playlistId: String, track: Track)
    func removeFromPlaylist(playlistId: String, trackId: String)
    func recordPlay(track: Track, durationPlayed: TimeInterval)
    func computeReplaySummary() -> ReplaySummary
    func downloadTrack(_ track: Track, resolver: StreamResolverProtocol) async
    func deleteDownload(trackId: String)
    func localFileURL(for trackId: String) -> URL?
    func scanLocalFolder(_ url: URL) async
    func removeLocalFolder(_ path: String)
    func addSearchHistory(_ query: String)
    func clearSearchHistory()
    func saveSettings(_ settings: AppSettings)
    func exportBackupJSON() throws -> Data
    func importBackupJSON(_ data: Data) throws
}

// MARK: - Discord Rich Presence Service

public protocol DiscordRPCProtocol: Sendable {
    var isConnected: Bool { get async }
    func connect() async
    func disconnect() async
    func updatePresence(
        track: Track,
        stream: ResolvedStream?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        settings: AppSettings
    ) async
    func clearPresence() async
}
