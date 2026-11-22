import AVFoundation
import Combine
import CoreMedia
import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - LibraryStore

@MainActor
public final class LibraryStore: ObservableObject, LibraryStoreProtocol {
    // MARK: - Published State

    @Published public private(set) var likedTracks: [Track] = []
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var history: [ListeningEvent] = []
    @Published public private(set) var downloads: [Track] = []
    @Published public private(set) var activeDownloads: [String: DownloadTaskState] = [:]
    @Published public private(set) var localTracks: [Track] = []
    @Published public private(set) var settings: AppSettings = .default
    @Published public private(set) var searchHistory: [String] = []

    // MARK: - Directories & Database

    public let baseDirectory: URL
    public let downloadsDirectory: URL
    public let artworkCacheDirectory: URL
    private let databaseURL: URL
    private let db: SQLiteStorage

    private var likedTrackIds: Set<String> = []
    private var inFlightDownloads: Set<String> = []

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    nonisolated private static let supportedAudioExtensions: Set<String> = [
        "m4a", "mp3", "flac", "wav", "aiff", "aif", "aac", "alac", "ogg"
    ]

    nonisolated private static let maxSearchHistoryItems = 30
    nonisolated private static let maxHistoryEvents = 20_000

    // MARK: - Init

    public nonisolated init(baseDirectory: URL? = nil) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let root = baseDirectory ?? appSupport.appendingPathComponent("SoundChord", isDirectory: true)

        // One-time migration from legacy BitChord storage before opening SQLite
        if baseDirectory == nil {
            let legacyRoot = appSupport.appendingPathComponent("BitChord", isDirectory: true)
            if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacyRoot.path) {
                try? fm.copyItem(at: legacyRoot, to: root)
                for suffix in ["", "-wal", "-shm"] {
                    let oldDB = root.appendingPathComponent("bitchord.sqlite\(suffix)")
                    let newDB = root.appendingPathComponent("soundchord.sqlite\(suffix)")
                    if fm.fileExists(atPath: oldDB.path), !fm.fileExists(atPath: newDB.path) {
                        try? fm.moveItem(at: oldDB, to: newDB)
                    }
                }
            }
        }

        let downloadsDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let artworkDir = root.appendingPathComponent("ArtworkCache", isDirectory: true)
        let dbURL = root.appendingPathComponent("soundchord.sqlite")

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        let storage = SQLiteStorage(url: dbURL)
        let initDecoder = JSONDecoder()
        initDecoder.dateDecodingStrategy = .iso8601

        let loadedSettings: AppSettings = storage.fetchKV(key: "settings")
            .flatMap { try? initDecoder.decode(AppSettings.self, from: $0) } ?? .default
        let loadedSearch: [String] = storage.fetchKV(key: "search_history")
            .flatMap { try? initDecoder.decode([String].self, from: $0) } ?? []
        let loadedLiked: [Track] = storage.fetchBlobs(sql: "SELECT payload FROM liked_tracks ORDER BY position ASC;")
            .compactMap { try? initDecoder.decode(Track.self, from: $0) }
        let loadedPlaylists: [Playlist] = storage.fetchBlobs(sql: "SELECT payload FROM playlists ORDER BY updated_at DESC;")
            .compactMap { try? initDecoder.decode(Playlist.self, from: $0) }
        let loadedHistory: [ListeningEvent] = storage.fetchBlobs(
            sql: "SELECT payload FROM listening_history ORDER BY played_at DESC LIMIT \(Self.maxHistoryEvents);"
        ).compactMap { try? initDecoder.decode(ListeningEvent.self, from: $0) }
        let loadedDownloads: [Track] = storage.fetchBlobs(sql: "SELECT payload FROM downloads ORDER BY added_at DESC;")
            .compactMap { try? initDecoder.decode(Track.self, from: $0) }
            .filter { track in
                guard let url = track.localFileURL else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
        let loadedLocal: [Track] = storage.fetchBlobs(sql: "SELECT payload FROM local_tracks;")
            .compactMap { try? initDecoder.decode(Track.self, from: $0) }
            .filter { track in
                guard let url = track.localFileURL else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        self.baseDirectory = root
        self.downloadsDirectory = downloadsDir
        self.artworkCacheDirectory = artworkDir
        self.databaseURL = dbURL
        self.db = storage

        let applyLoadedState: @MainActor () -> Void = {
            self.likedTracks = loadedLiked
            self.likedTrackIds = Set(loadedLiked.map(\.id))
            self.playlists = loadedPlaylists
            self.history = loadedHistory
            self.downloads = loadedDownloads
            self.localTracks = loadedLocal
            self.settings = loadedSettings
            self.searchHistory = loadedSearch
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated(applyLoadedState)
        } else {
            Task { @MainActor in
                applyLoadedState()
            }
        }
    }

    // MARK: - Likes

    public func isLiked(_ trackId: String) -> Bool {
        likedTrackIds.contains(trackId)
    }

    public func toggleLike(_ track: Track) {
        if let idx = likedTracks.firstIndex(where: { $0.id == track.id }) {
            likedTracks.remove(at: idx)
            likedTrackIds.remove(track.id)
        } else {
            likedTracks.insert(track, at: 0)
            likedTrackIds.insert(track.id)
        }
        persistLikedTracks()
    }

    // MARK: - Playlists

    @discardableResult
    public func createPlaylist(title: String, description: String? = nil) -> Playlist {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let playlist = Playlist(
            id: "local_pl_\(UUID().uuidString)",
            title: cleaned.isEmpty ? "Untitled Playlist" : cleaned,
            author: "You",
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURL: nil,
            tracks: [],
            isUserCreated: true,
            createdAt: now,
            updatedAt: now
        )
        playlists.insert(playlist, at: 0)
        persistPlaylist(playlist)
        return playlist
    }

    public func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        db.deleteRow(table: "playlists", id: id)
    }

    public func renamePlaylist(id: String, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].title = cleaned
        playlists[idx].updatedAt = Date()
        persistPlaylist(playlists[idx])
    }

    public func addToPlaylist(playlistId: String, track: Track) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        if !playlists[idx].tracks.contains(where: { $0.id == track.id }) {
            playlists[idx].tracks.append(track)
            if playlists[idx].artworkURL == nil {
                playlists[idx].artworkURL = track.artworkURL
            }
            playlists[idx].updatedAt = Date()
            persistPlaylist(playlists[idx])
        }
    }

    public func removeFromPlaylist(playlistId: String, trackId: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[idx].tracks.removeAll { $0.id == trackId }
        if playlists[idx].tracks.isEmpty {
            playlists[idx].artworkURL = nil
        } else if playlists[idx].artworkURL == nil {
            playlists[idx].artworkURL = playlists[idx].tracks.first?.artworkURL
        }
        playlists[idx].updatedAt = Date()
        persistPlaylist(playlists[idx])
    }

    public func reorderPlaylistTracks(playlistId: String, from source: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[idx].tracks = Self.moveElements(playlists[idx].tracks, from: source, to: destination)
        playlists[idx].updatedAt = Date()
        persistPlaylist(playlists[idx])
    }

    // MARK: - Listening History & Replay

    public func recordPlay(track: Track, durationPlayed: TimeInterval) {
        guard durationPlayed.isFinite && durationPlayed > 0 else { return }
        let event = ListeningEvent(
            track: track,
            playedAt: Date(),
            durationPlayed: durationPlayed
        )
        history.insert(event, at: 0)
        if history.count > Self.maxHistoryEvents {
            history = Array(history.prefix(Self.maxHistoryEvents))
        }
        persistListeningEvent(event)
    }

    public func computeReplaySummary() -> ReplaySummary {
        guard !history.isEmpty else {
            return ReplaySummary(periodLabel: "All Time")
        }

        var totalSeconds: TimeInterval = 0
        var trackStats: [String: (track: Track, count: Int, seconds: TimeInterval)] = [:]
        var artistStats: [String: (name: String, id: String?, artwork: URL?, count: Int, seconds: TimeInterval)] = [:]
        var albumStats: [String: (title: String, artist: String, id: String?, artwork: URL?, count: Int)] = [:]
        var monthlySeconds: [String: TimeInterval] = [:]
        var hourlySeconds: [Int: TimeInterval] = [:]
        var uniqueDays = Set<Date>()

        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = Calendar(identifier: .gregorian)
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"

        for event in history {
            let played = max(0, event.durationPlayed)
            totalSeconds += played

            // Track aggregation
            let trackKey = event.track.id
            if var existing = trackStats[trackKey] {
                existing.count += 1
                existing.seconds += played
                trackStats[trackKey] = existing
            } else {
                trackStats[trackKey] = (event.track, 1, played)
            }

            // Artist aggregation
            let artistName = event.track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !artistName.isEmpty {
                let artistKey = event.track.artistId ?? artistName.lowercased()
                if var existing = artistStats[artistKey] {
                    existing.count += 1
                    existing.seconds += played
                    if existing.artwork == nil { existing.artwork = event.track.artworkURL }
                    artistStats[artistKey] = existing
                } else {
                    artistStats[artistKey] = (artistName, event.track.artistId, event.track.artworkURL, 1, played)
                }
            }

            // Album aggregation
            if let rawAlbum = event.track.album?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawAlbum.isEmpty {
                let albumKey = event.track.albumId ?? "\(artistName.lowercased())::\(rawAlbum.lowercased())"
                if var existing = albumStats[albumKey] {
                    existing.count += 1
                    if existing.artwork == nil { existing.artwork = event.track.artworkURL }
                    albumStats[albumKey] = existing
                } else {
                    albumStats[albumKey] = (rawAlbum, artistName, event.track.albumId, event.track.artworkURL, 1)
                }
            }

            // Monthly breakdown
            let monthKey = monthFormatter.string(from: event.playedAt)
            monthlySeconds[monthKey, default: 0] += played

            // Peak hour & streaks
            let hour = calendar.component(.hour, from: event.playedAt)
            hourlySeconds[hour, default: 0] += played
            uniqueDays.insert(calendar.startOfDay(for: event.playedAt))
        }

        let topTracks = trackStats.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.seconds > rhs.seconds
            }
            .prefix(25)
            .map { RankedTrack(track: $0.track, playCount: $0.count, totalSeconds: $0.seconds) }

        let topArtists = artistStats.values
            .sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
                return lhs.count > rhs.count
            }
            .prefix(20)
            .map {
                RankedArtist(
                    name: $0.name,
                    artistId: $0.id,
                    artworkURL: $0.artwork,
                    playCount: $0.count,
                    totalSeconds: $0.seconds
                )
            }

        let topAlbums = albumStats.values
            .sorted { $0.count > $1.count }
            .prefix(20)
            .map {
                RankedAlbum(
                    title: $0.title,
                    artist: $0.artist,
                    albumId: $0.id,
                    artworkURL: $0.artwork,
                    playCount: $0.count
                )
            }

        var monthlyMinutes: [String: Int] = [:]
        for (month, secs) in monthlySeconds {
            monthlyMinutes[month] = max(secs > 0 ? 1 : 0, Int((secs / 60.0).rounded()))
        }

        let longestStreak = Self.computeLongestDayStreak(days: uniqueDays, calendar: calendar)
        let peakHour = hourlySeconds.max(by: { $0.value < $1.value })?.key

        return ReplaySummary(
            periodLabel: "All Time",
            totalMinutes: Int((totalSeconds / 60.0).rounded()),
            totalPlays: history.count,
            uniqueTracksCount: trackStats.count,
            uniqueArtistsCount: artistStats.count,
            topTracks: Array(topTracks),
            topArtists: Array(topArtists),
            topAlbums: Array(topAlbums),
            monthlyMinutes: monthlyMinutes,
            longestStreakDays: longestStreak,
            peakListeningHour: peakHour
        )
    }

    // MARK: - Downloads

    public func downloadTrack(_ track: Track, resolver: StreamResolverProtocol) async {
        // Already downloaded & present on disk?
        if let existing = localFileURL(for: track.id),
           FileManager.default.fileExists(atPath: existing.path) {
            return
        }

        guard !inFlightDownloads.contains(track.id) else { return }
        inFlightDownloads.insert(track.id)
        defer { inFlightDownloads.remove(track.id) }

        activeDownloads[track.id] = DownloadTaskState(
            track: track,
            progress: 0,
            status: .queued
        )

        do {
            var stream = try await resolver.resolveStream(
                videoId: track.videoId,
                quality: settings.downloadQuality
            )

            // If lossless returned an HLS manifest, retry with .high for a direct audio file
            if stream.isHLS && settings.downloadQuality == .lossless {
                if let direct = try? await resolver.resolveStream(videoId: track.videoId, quality: .high),
                   !direct.isHLS {
                    stream = direct
                }
            }

            if stream.isHLS {
                throw BitChordError.storageFailure("HLS stream cannot be downloaded directly as a single file.")
            }

            activeDownloads[track.id] = DownloadTaskState(
                track: track,
                progress: 0.02,
                status: .downloading
            )

            let fileExtension = Self.fileExtension(for: stream)
            let safeName = Self.sanitizeFilename(track.videoId.isEmpty ? track.id : track.videoId)
            let destinationURL = downloadsDirectory.appendingPathComponent("\(safeName).\(fileExtension)")

            var request = URLRequest(url: stream.url)
            request.timeoutInterval = 120
            for (header, value) in stream.requestHeaders {
                request.setValue(value, forHTTPHeaderField: header)
            }

            let trackId = track.id
            try await Self.performDownload(
                request: request,
                destinationURL: destinationURL,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, var current = self.activeDownloads[trackId] else { return }
                        current.status = .downloading
                        current.progress = max(0.02, min(0.99, progress))
                        self.activeDownloads[trackId] = current
                    }
                }
            )

            var downloadedTrack = track
            downloadedTrack.localFileURL = destinationURL
            downloadedTrack.isDownloaded = true
            downloadedTrack.qualityLabel = stream.qualityLabel
            downloadedTrack.audioCodec = stream.codec
            downloadedTrack.bitrateKbps = stream.bitrateKbps
            downloadedTrack.sampleRateHz = stream.sampleRateHz
            downloadedTrack.bitDepth = stream.bitDepth

            if let existingIdx = downloads.firstIndex(where: { $0.id == downloadedTrack.id }) {
                downloads[existingIdx] = downloadedTrack
            } else {
                downloads.insert(downloadedTrack, at: 0)
            }
            persistDownload(downloadedTrack)

            activeDownloads[track.id] = DownloadTaskState(
                track: downloadedTrack,
                progress: 1.0,
                status: .completed
            )

            // Clear completed indicator after brief visibility window
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self?.activeDownloads[trackId]?.status == .completed {
                    self?.activeDownloads.removeValue(forKey: trackId)
                }
            }
        } catch {
            activeDownloads[track.id] = DownloadTaskState(
                track: track,
                progress: 0,
                status: .failed,
                error: error.localizedDescription
            )
        }
    }

    public func deleteDownload(trackId: String) {
        if let idx = downloads.firstIndex(where: { $0.id == trackId || $0.videoId == trackId }) {
            let track = downloads.remove(at: idx)
            if let fileURL = track.localFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            db.deleteRow(table: "downloads", id: track.id)
        }
        activeDownloads.removeValue(forKey: trackId)
    }

    public func localFileURL(for trackId: String) -> URL? {
        if let match = downloads.first(where: { $0.id == trackId || $0.videoId == trackId }),
           let url = match.localFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let match = localTracks.first(where: { $0.id == trackId || $0.videoId == trackId }),
           let url = match.localFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - Local Music Folder Scanning

    public func scanLocalFolder(_ url: URL) async {
        let standardized = url.standardizedFileURL
        let folderPath = standardized.path

        if !settings.localMusicFolders.contains(folderPath) {
            var updated = settings
            updated.localMusicFolders.append(folderPath)
            saveSettings(updated)
        }

        let artworkDir = artworkCacheDirectory
        let scanned: [Track] = await Task.detached(priority: .utility) {
            await Self.scanDirectoryForAudioFiles(folderURL: standardized, artworkCacheDir: artworkDir)
        }.value

        // Replace previous entries from this folder while keeping tracks from other folders
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        localTracks.removeAll { track in
            guard let path = track.localFileURL?.standardizedFileURL.path else { return false }
            return path == folderPath || path.hasPrefix(prefix)
        }
        localTracks.append(contentsOf: scanned)
        localTracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        persistLocalTracks()
    }

    public func removeLocalFolder(_ path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var updated = settings
        updated.localMusicFolders.removeAll {
            URL(fileURLWithPath: $0).standardizedFileURL.path == standardizedPath
        }
        saveSettings(updated)

        let prefix = standardizedPath.hasSuffix("/") ? standardizedPath : standardizedPath + "/"
        localTracks.removeAll { track in
            guard let filePath = track.localFileURL?.standardizedFileURL.path else { return false }
            return filePath == standardizedPath || filePath.hasPrefix(prefix)
        }
        persistLocalTracks()
    }

    // MARK: - Search History

    public func addSearchHistory(_ query: String) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        searchHistory.insert(cleaned, at: 0)
        if searchHistory.count > Self.maxSearchHistoryItems {
            searchHistory = Array(searchHistory.prefix(Self.maxSearchHistoryItems))
        }
        persistKV(key: "search_history", value: searchHistory)
    }

    public func clearSearchHistory() {
        searchHistory = []
        persistKV(key: "search_history", value: searchHistory)
    }

    // MARK: - Settings

    public func saveSettings(_ settings: AppSettings) {
        self.settings = settings
        persistKV(key: "settings", value: settings)
    }

    // MARK: - Backup Export & Import

    public func exportBackupJSON() throws -> Data {
        let payload = AppBackupPayload(
            version: 1,
            exportedAt: Date(),
            likedTracks: likedTracks,
            playlists: playlists,
            history: history,
            searchHistory: searchHistory,
            settings: settings
        )
        let prettyEncoder = JSONEncoder()
        prettyEncoder.dateEncodingStrategy = .iso8601
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try prettyEncoder.encode(payload)
        } catch {
            throw BitChordError.storageFailure("Failed to export backup: \(error.localizedDescription)")
        }
    }

    public func importBackupJSON(_ data: Data) throws {
        let payload: AppBackupPayload
        do {
            payload = try decoder.decode(AppBackupPayload.self, from: data)
        } catch {
            throw BitChordError.storageFailure("Invalid backup JSON: \(error.localizedDescription)")
        }

        guard payload.version >= 1 else {
            throw BitChordError.storageFailure("Unsupported backup version: \(payload.version)")
        }

        likedTracks = payload.likedTracks
        likedTrackIds = Set(likedTracks.map(\.id))
        playlists = payload.playlists
        history = Array(payload.history.prefix(Self.maxHistoryEvents))
        searchHistory = Array(payload.searchHistory.prefix(Self.maxSearchHistoryItems))
        settings = payload.settings

        persistLikedTracks()
        persistAllPlaylists()
        persistAllHistory()
        persistKV(key: "search_history", value: searchHistory)
        persistKV(key: "settings", value: settings)
    }

    // MARK: - Chord Timeline Cache

    public func loadChordTimeline(trackId: String) -> TrackChordTimeline? {
        guard !trackId.isEmpty,
              let data = db.fetchChordTimeline(trackId: trackId) else {
            return nil
        }
        return try? decoder.decode(TrackChordTimeline.self, from: data)
    }

    public func saveChordTimeline(_ timeline: TrackChordTimeline) {
        guard !timeline.trackId.isEmpty,
              let data = try? encoder.encode(timeline),
              let jsonText = String(data: data, encoding: .utf8) else {
            return
        }
        db.upsertChordTimeline(
            trackId: timeline.trackId,
            payload: jsonText,
            updatedAt: timeline.analyzedAt.timeIntervalSince1970
        )
    }

    public func deleteChordTimeline(trackId: String) {
        guard !trackId.isEmpty else { return }
        db.deleteChordTimeline(trackId: trackId)
    }

    // MARK: - Database Persistence

    private func persistKV<T: Encodable>(key: String, value: T) {
        guard let data = try? encoder.encode(value) else { return }
        db.upsertKV(key: key, data: data)
    }

    private func persistLikedTracks() {
        db.inTransaction {
            db.execute("DELETE FROM liked_tracks;")
            for (index, track) in likedTracks.enumerated() {
                if let data = try? encoder.encode(track) {
                    db.insertLikedTrack(id: track.id, position: index, payload: data)
                }
            }
        }
    }

    private func persistPlaylist(_ playlist: Playlist) {
        guard let data = try? encoder.encode(playlist) else { return }
        db.upsertPlaylist(id: playlist.id, updatedAt: playlist.updatedAt.timeIntervalSince1970, payload: data)
    }

    private func persistAllPlaylists() {
        db.inTransaction {
            db.execute("DELETE FROM playlists;")
            for playlist in playlists {
                if let data = try? encoder.encode(playlist) {
                    db.upsertPlaylist(id: playlist.id, updatedAt: playlist.updatedAt.timeIntervalSince1970, payload: data)
                }
            }
        }
    }

    private func persistListeningEvent(_ event: ListeningEvent) {
        guard let data = try? encoder.encode(event) else { return }
        db.insertListeningEvent(
            id: event.id.uuidString,
            trackId: event.track.id,
            playedAt: event.playedAt.timeIntervalSince1970,
            durationPlayed: event.durationPlayed,
            payload: data
        )
    }

    private func persistAllHistory() {
        db.inTransaction {
            db.execute("DELETE FROM listening_history;")
            for event in history {
                if let data = try? encoder.encode(event) {
                    db.insertListeningEvent(
                        id: event.id.uuidString,
                        trackId: event.track.id,
                        playedAt: event.playedAt.timeIntervalSince1970,
                        durationPlayed: event.durationPlayed,
                        payload: data
                    )
                }
            }
        }
    }

    private func persistDownload(_ track: Track) {
        guard let data = try? encoder.encode(track),
              let path = track.localFileURL?.path else { return }
        db.upsertDownload(id: track.id, localPath: path, addedAt: Date().timeIntervalSince1970, payload: data)
    }

    private func persistLocalTracks() {
        db.inTransaction {
            db.execute("DELETE FROM local_tracks;")
            for track in localTracks {
                guard let data = try? encoder.encode(track),
                      let fileURL = track.localFileURL else { continue }
                let folderPath = fileURL.deletingLastPathComponent().path
                db.upsertLocalTrack(id: track.id, folderPath: folderPath, filePath: fileURL.path, payload: data)
            }
        }
    }

    // MARK: - Download Execution

    nonisolated private static func performDownload(
        request: URLRequest,
        destinationURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = TrackDownloadDelegate(
            destinationURL: destinationURL,
            onProgress: onProgress
        )
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await delegate.start(request: request, on: session)
        } onCancel: {
            delegate.cancel()
        }
    }

    nonisolated private static func fileExtension(for stream: ResolvedStream) -> String {
        let mime = stream.mimeType.lowercased()
        let codec = stream.codec.lowercased()
        if mime.contains("flac") || codec.contains("flac") { return "flac" }
        if mime.contains("mpeg") || mime.contains("mp3") || codec.contains("mp3") { return "mp3" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("aiff") { return "aiff" }
        if mime.contains("ogg") || codec.contains("vorbis") { return "ogg" }
        return "m4a"
    }

    nonisolated private static func sanitizeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? UUID().uuidString : String(str.prefix(96))
    }

    // MARK: - Local Audio Scanner (Background)

    nonisolated private static func scanDirectoryForAudioFiles(
        folderURL: URL,
        artworkCacheDir: URL
    ) async -> [Track] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var audioURLs: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            let ext = next.pathExtension.lowercased()
            guard supportedAudioExtensions.contains(ext) else { continue }
            if let values = try? next.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                audioURLs.append(next.standardizedFileURL)
            }
        }

        var tracks: [Track] = []
        tracks.reserveCapacity(audioURLs.count)

        for fileURL in audioURLs {
            if let track = await extractLocalTrackMetadata(fileURL: fileURL, artworkCacheDir: artworkCacheDir) {
                tracks.append(track)
            }
        }
        return tracks
    }

    nonisolated private static func extractLocalTrackMetadata(
        fileURL: URL,
        artworkCacheDir: URL
    ) async -> Track? {
        let asset = AVURLAsset(url: fileURL)
        let hashId = sha256Hex(fileURL.path)
        let trackId = "local:\(hashId.prefix(24))"

        let fallbackTitle = fileURL.deletingPathExtension().lastPathComponent
        let parentName = fileURL.deletingLastPathComponent().lastPathComponent

        var title = fallbackTitle
        var artist = parentName.isEmpty ? "Unknown Artist" : parentName
        var album: String? = nil
        var durationSeconds: TimeInterval = 0
        var artworkURL: URL? = nil

        if let duration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(duration)
            if secs.isFinite && secs > 0 {
                durationSeconds = secs
            }
        }

        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let val = try? await item.load(.stringValue), !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyArtist:
                    if let val = try? await item.load(.stringValue), !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        artist = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyAlbumName:
                    if let val = try? await item.load(.stringValue), !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        album = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue), !data.isEmpty {
                        let cachedURL = artworkCacheDir.appendingPathComponent("\(hashId.prefix(24)).jpg")
                        if !FileManager.default.fileExists(atPath: cachedURL.path) {
                            try? data.write(to: cachedURL, options: .atomic)
                        }
                        artworkURL = cachedURL
                    }
                default:
                    break
                }
            }
        }

        // Inspect audio track format details (codec, sample rate, bit depth, bitrate)
        var audioCodec: String? = fileURL.pathExtension.uppercased()
        var bitrateKbps: Int? = nil
        var sampleRateHz: Int? = nil
        var bitDepth: Int? = nil
        var isLossless = false

        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let firstTrack = audioTracks.first {
            if let dataRate = try? await firstTrack.load(.estimatedDataRate), dataRate > 0 {
                bitrateKbps = Int((dataRate / 1000.0).rounded())
            }
            if let descriptions = try? await firstTrack.load(.formatDescriptions),
               let desc = descriptions.first {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    let asbd = asbdPtr.pointee
                    if asbd.mSampleRate > 0 {
                        sampleRateHz = Int(asbd.mSampleRate.rounded())
                    }
                    if asbd.mBitsPerChannel > 0 {
                        bitDepth = Int(asbd.mBitsPerChannel)
                    }
                }
                let parsed = describeAudioSubType(subType, fallbackExtension: fileURL.pathExtension)
                audioCodec = parsed.codec
                isLossless = parsed.isLossless
            }
        }

        let qualityLabel: String
        if isLossless {
            if (sampleRateHz ?? 0) >= 48_000 && ((bitDepth ?? 16) >= 24 || (sampleRateHz ?? 0) >= 88_200) {
                qualityLabel = "Hi-Res Lossless"
            } else {
                qualityLabel = "Lossless"
            }
        } else {
            qualityLabel = "Local"
        }

        return Track(
            id: trackId,
            videoId: trackId,
            title: title,
            artist: artist,
            album: album,
            duration: durationSeconds,
            artworkURL: artworkURL,
            localFileURL: fileURL,
            isDownloaded: true,
            isLocal: true,
            qualityLabel: qualityLabel,
            audioCodec: audioCodec,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            bitDepth: bitDepth
        )
    }

    nonisolated private static func describeAudioSubType(
        _ subType: FourCharCode,
        fallbackExtension: String
    ) -> (codec: String, isLossless: Bool) {
        switch subType {
        case kAudioFormatAppleLossless:
            return ("ALAC", true)
        case kAudioFormatFLAC:
            return ("FLAC", true)
        case kAudioFormatLinearPCM:
            return ("PCM", true)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
            return ("AAC", false)
        case kAudioFormatMPEGLayer3:
            return ("MP3", false)
        case kAudioFormatOpus:
            return ("OPUS", false)
        default:
            let ext = fallbackExtension.uppercased()
            let losslessExts: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF", "AIF"]
            return (ext.isEmpty ? "AUDIO" : ext, losslessExts.contains(ext))
        }
    }

    nonisolated private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func computeLongestDayStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1
        var current = 1
        for idx in 1..<sorted.count {
            let prev = sorted[idx - 1]
            let curr = sorted[idx]
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(nextDay, inSameDayAs: curr) {
                current += 1
                best = max(best, current)
            } else {
                current = 1
            }
        }
        return best
    }

    private static func moveElements<T>(_ array: [T], from source: IndexSet, to destination: Int) -> [T] {
        var result = array
        let moving = source.sorted().compactMap { $0 < result.count ? result[$0] : nil }
        for index in source.sorted(by: >) where index < result.count {
            result.remove(at: index)
        }
        let removedBeforeDest = source.filter { $0 < destination }.count
        let insertIndex = max(0, min(result.count, destination - removedBeforeDest))
        result.insert(contentsOf: moving, at: insertIndex)
        return result
    }
}

// MARK: - URLSession Download Delegate

private final class TrackDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var lastReportedProgress: Double = -1

    init(destinationURL: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
    }

    func start(request: URLRequest, on session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = cont
            let downloadTask = session.downloadTask(with: request)
            self.task = downloadTask
            lock.unlock()
            downloadTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        task = nil
        lock.unlock()
        switch result {
        case .success:
            cont?.resume()
        case .failure(let error):
            cont?.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        let shouldReport = (progress - lastReportedProgress) >= 0.01 || progress >= 0.99
        if shouldReport {
            lastReportedProgress = progress
        }
        lock.unlock()
        if shouldReport {
            onProgress(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw BitChordError.httpError(http.statusCode, "Download server returned HTTP \(http.statusCode)")
            }
            let fm = FileManager.default
            let parent = destinationURL.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }
}

// MARK: - SQLite3 Storage Layer

private final class SQLiteStorage: @unchecked Sendable {
    private var db: OpaquePointer?

    init(url: URL) {
        if sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK {
            execute("PRAGMA journal_mode = WAL;")
            execute("PRAGMA synchronous = NORMAL;")
            createSchema()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func createSchema() {
        execute("""
        CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS liked_tracks (
            id TEXT PRIMARY KEY,
            position INTEGER NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS listening_history (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            played_at REAL NOT NULL,
            duration_played REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_history_played_at ON listening_history(played_at DESC);")
        execute("""
        CREATE TABLE IF NOT EXISTS downloads (
            id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL,
            added_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS local_tracks (
            id TEXT PRIMARY KEY,
            folder_path TEXT NOT NULL,
            file_path TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS chord_timelines (
            track_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
    }

    func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func inTransaction(_ work: () -> Void) {
        execute("BEGIN IMMEDIATE TRANSACTION;")
        work()
        execute("COMMIT;")
    }

    func deleteRow(table: String, id: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM \(table) WHERE id = ?;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
    }

    func upsertKV(key: String, data: Data) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO kv_store (key, value, updated_at) VALUES (?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            bindBlob(stmt, index: 2, data: data)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func fetchKV(key: String) -> Data? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM kv_store WHERE key = ? LIMIT 1;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return extractBlob(stmt, column: 0)
            }
        }
        return nil
    }

    func insertLikedTrack(id: String, position: Int, payload: Data) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO liked_tracks (id, position, payload) VALUES (?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(position))
            bindBlob(stmt, index: 3, data: payload)
            sqlite3_step(stmt)
        }
    }

    func upsertPlaylist(id: String, updatedAt: TimeInterval, payload: Data) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO playlists (id, updated_at, payload) VALUES (?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 2, updatedAt)
            bindBlob(stmt, index: 3, data: payload)
            sqlite3_step(stmt)
        }
    }

    func insertListeningEvent(
        id: String,
        trackId: String,
        playedAt: TimeInterval,
        durationPlayed: TimeInterval,
        payload: Data
    ) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO listening_history (id, track_id, played_at, duration_played, payload) VALUES (?, ?, ?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, trackId, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 3, playedAt)
            sqlite3_bind_double(stmt, 4, durationPlayed)
            bindBlob(stmt, index: 5, data: payload)
            sqlite3_step(stmt)
        }
    }

    func upsertDownload(id: String, localPath: String, addedAt: TimeInterval, payload: Data) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO downloads (id, local_path, added_at, payload) VALUES (?, ?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, localPath, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 3, addedAt)
            bindBlob(stmt, index: 4, data: payload)
            sqlite3_step(stmt)
        }
    }

    func upsertLocalTrack(id: String, folderPath: String, filePath: String, payload: Data) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO local_tracks (id, folder_path, file_path, payload) VALUES (?, ?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, folderPath, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, filePath, -1, sqliteTransient)
            bindBlob(stmt, index: 4, data: payload)
            sqlite3_step(stmt)
        }
    }

    func upsertChordTimeline(trackId: String, payload: String, updatedAt: TimeInterval) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO chord_timelines (track_id, payload, updated_at) VALUES (?, ?, ?);"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, trackId, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, payload, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 3, updatedAt)
            sqlite3_step(stmt)
        }
    }

    func fetchChordTimeline(trackId: String) -> Data? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT payload FROM chord_timelines WHERE track_id = ? LIMIT 1;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, trackId, -1, sqliteTransient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return extractBlob(stmt, column: 0)
            }
        }
        return nil
    }

    func deleteChordTimeline(trackId: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM chord_timelines WHERE track_id = ?;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, trackId, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
    }

    func fetchBlobs(sql: String) -> [Data] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        var results: [Data] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let data = extractBlob(stmt, column: 0) {
                    results.append(data)
                }
            }
        }
        return results
    }

    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            _ = sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    private func extractBlob(_ stmt: OpaquePointer?, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return Data(bytes: bytes, count: count)
    }
}
