import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    // MARK: - Concrete Services

    public let innerTube: InnerTubeClient
    public let streamResolver: StreamResolver
    public let lyricsEngine: LyricsEngine
    public let audioEngine: AudioEngine
    public let libraryStore: LibraryStore
    public let discordRPC: DiscordRPC
    public let addonManager: AddonManager

    // MARK: - Navigation & Chrome State

    @Published public var selectedSidebar: SidebarItem = .home
    @Published public var navigationPath = NavigationPath()
    @Published public var showRightDrawer: Bool = false
    @Published public var rightDrawerTab: RightDrawerTab = .queue
    @Published public var showFullScreenPlayer: Bool = false
    @Published public var showStatsForNerds: Bool = false
    @Published public var showImportPlaylistSheet: Bool = false
    @Published public var artworkPaletteColors: [Color] = AppState.defaultPaletteColors

    // MARK: - Browse & Search State

    @Published public var homeShelves: [ShelfSection] = []
    @Published public var exploreShelves: [ShelfSection] = []
    @Published public var isLoadingHome: Bool = false
    @Published public var isLoadingExplore: Bool = false

    @Published public var searchQuery: String = ""
    @Published public var searchSuggestions: [SearchSuggestion] = []
    @Published public var searchResults: SearchResults?
    @Published public var isSearching: Bool = false
    @Published public var addonSearchResults: [Track] = []
    @Published public var isSearchingAddons: Bool = false

    // MARK: - Lyrics State

    @Published public var currentLyrics: LyricsDocument?
    @Published public var isLoadingLyrics: Bool = false
    @Published public var isTranslatingLyrics: Bool = false
    @Published public var showTranslatedLyrics: Bool = false

    // MARK: - Chord Timeline Analysis State

    @Published public var currentChordTimeline: TrackChordTimeline? = nil
    @Published public var isAnalyzingChords: Bool = false
    @Published public var chordAnalysisProgress: Double = 0.0
    @Published public var chordAnalysisStatus: String? = nil
    @Published public var chordAnalysisError: String? = nil

    // MARK: - Status & Feedback

    @Published public var isDiscordConnected: Bool = false
    @Published public var errorBanner: String?
    @Published public var toastMessage: String?

    // MARK: - Internal State

    private var cancellables = Set<AnyCancellable>()
    private var lyricsTask: Task<Void, Never>?
    private var chordAnalysisTask: Task<Void, Never>?
    private var activeChordAnalysisRunId: UUID?
    private var activeChordAnalysisTrackId: String?
    private var activeChordAnalysisSimpleMode: Bool?
    private var paletteTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastPaletteArtworkURL: URL?

    /// Upstream BitChord fallback 4-blob mesh gradient palette (`MeshGradient.kt`).
    public static let defaultPaletteColors: [Color] = [
        Color(red: 0x3A / 255.0, green: 0x1C / 255.0, blue: 0x71 / 255.0),
        Color(red: 0xD7 / 255.0, green: 0x6D / 255.0, blue: 0x77 / 255.0),
        Color(red: 0x2B / 255.0, green: 0x58 / 255.0, blue: 0x76 / 255.0),
        Color(red: 0xFF / 255.0, green: 0xAF / 255.0, blue: 0x7B / 255.0)
    ]

    // MARK: - Initialization

    public init(
        innerTube: InnerTubeClient = InnerTubeClient(),
        streamResolver: StreamResolver = StreamResolver(),
        lyricsEngine: LyricsEngine = LyricsEngine(),
        libraryStore: LibraryStore = LibraryStore(),
        discordRPC: DiscordRPC = DiscordRPC(),
        addonManager: AddonManager? = nil,
        audioEngine: AudioEngine? = nil
    ) {
        self.innerTube = innerTube
        self.streamResolver = streamResolver
        self.lyricsEngine = lyricsEngine
        self.libraryStore = libraryStore
        self.discordRPC = discordRPC
        self.addonManager = addonManager ?? AddonManager()
        self.audioEngine = audioEngine ?? AudioEngine(streamResolver: streamResolver)

        bindServices()
        applyCurrentSettingsToAudioEngine()
    }

    private func bindServices() {
        // Forward discrete ObservableObject updates so views observing AppState stay in sync.
        // High-frequency playback clock values live on audioEngine.clock so steady playback
        // emits zero AppState.objectWillChange ticks per second.
        audioEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        libraryStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        addonManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Surface asynchronous AVPlayerItem failures via errorBanner.
        audioEngine.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.showError(message)
            }
            .store(in: &cancellables)

        // Route direct addon tracks & automatic Lossless YouTube upgrades through AddonManager.
        audioEngine.customStreamResolver = { [weak self] track, quality in
            guard let self else { return nil }
            if let configId = track.addonConfigId, let addonTrackId = track.addonTrackId {
                return try await self.addonManager.resolveDirectAddonStream(
                    configId: configId,
                    addonTrackId: addonTrackId,
                    quality: quality
                )
            }
            let settings = self.libraryStore.settings
            if !track.isLocal,
               !track.isDownloaded,
               quality == .lossless,
               settings.addonLosslessUpgrade {
                return await self.addonManager.resolveLosslessSubstitute(
                    for: track,
                    quality: quality,
                    durationToleranceSec: settings.addonDurationToleranceSec
                )
            }
            return nil
        }

        audioEngine.onTrackChanged = { [weak self] track, stream in
            guard let self else { return }
            self.handleTrackChanged(track, stream: stream)
        }

        audioEngine.onPlaybackStateChanged = { [weak self] isPlaying, elapsed, duration in
            guard let self else { return }
            self.handlePlaybackStateChanged(isPlaying: isPlaying, elapsed: elapsed, duration: duration)
        }

        audioEngine.onTrackEnded = { [weak self] track, playedSeconds in
            guard let self else { return }
            if playedSeconds >= 10 {
                self.libraryStore.recordPlay(track: track, durationPlayed: playedSeconds)
            }
        }

        audioEngine.onNeedRadioTracks = { [weak self] track in
            guard let self, !track.isLocal, track.addonConfigId == nil, !track.videoId.isEmpty else { return [] }
            return (try? await self.innerTube.fetchUpNextRadio(videoId: track.videoId)) ?? []
        }
    }

    // MARK: - Lifecycle Bootstrap

    public func bootstrap() async {
        // Re-confirm macOS MPRemoteCommandCenter registration after NSApplication finishes launching
        audioEngine.ensureRemoteCommandsRegistered()

        let settings = libraryStore.settings
        if !settings.ytCookieHeader.isEmpty {
            await innerTube.setCookie(settings.ytCookieHeader)
            await streamResolver.setCookie(settings.ytCookieHeader)
        }
        applyCurrentSettingsToAudioEngine()

        if settings.discordRPCEnabled {
            await discordRPC.connect()
            isDiscordConnected = await discordRPC.isConnected
        }

        Task { [weak self] in
            await self?.addonManager.refreshAllHealth()
        }

        await loadHome(force: false)
    }

    // MARK: - Browse & Discovery

    public func loadHome(force: Bool = false) async {
        guard force || homeShelves.isEmpty else { return }
        guard !isLoadingHome else { return }
        isLoadingHome = true
        defer { isLoadingHome = false }

        do {
            let shelves = try await innerTube.fetchHome()
            homeShelves = shelves
            errorBanner = nil
        } catch {
            showError("Could not load Home feed: \(error.localizedDescription)")
        }
    }

    public func loadExplore(force: Bool = false) async {
        guard force || exploreShelves.isEmpty else { return }
        guard !isLoadingExplore else { return }
        isLoadingExplore = true
        defer { isLoadingExplore = false }

        do {
            let shelves = try await innerTube.fetchExplore()
            exploreShelves = shelves
            errorBanner = nil
        } catch {
            showError("Could not load Explore feed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search

    public func updateSearchSuggestions(for query: String) {
        searchQuery = query
        suggestionTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchSuggestions = []
            return
        }

        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            if let suggestions = try? await self.innerTube.fetchSearchSuggestions(query: trimmed) {
                if !Task.isCancelled {
                    self.searchSuggestions = suggestions
                }
            }
        }
    }

    public func performSearch(_ rawQuery: String? = nil) async {
        let query = (rawQuery ?? searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            addonSearchResults = []
            return
        }
        searchQuery = query
        searchSuggestions = []
        libraryStore.addSearchHistory(query)

        isSearching = true
        isSearchingAddons = true
        let quality = libraryStore.settings.streamQuality

        let addonTask = Task { [weak self] () -> [Track] in
            guard let self else { return [] }
            return await self.addonManager.searchAddons(query: query, quality: quality)
        }

        do {
            searchResults = try await innerTube.search(query: query)
            errorBanner = nil
        } catch {
            showError("Search failed: \(error.localizedDescription)")
        }
        isSearching = false

        let addonHits = await addonTask.value
        if searchQuery == query {
            addonSearchResults = addonHits
        }
        isSearchingAddons = false
    }

    // MARK: - Playback Coordination

    public func play(track: Track, queue: [Track]? = nil) {
        let enrichedTrack = enrichTrackWithLocalDownload(track)
        let enrichedQueue = queue?.map { enrichTrackWithLocalDownload($0) }

        Task { [weak self] in
            guard let self else { return }
            await self.audioEngine.play(track: enrichedTrack, queue: enrichedQueue)
            if let err = self.audioEngine.lastError {
                self.showError(err)
            }
        }
    }

    public func playAlbum(_ album: Album, startingAt index: Int = 0, shuffled: Bool = false) {
        guard !album.tracks.isEmpty else { return }
        var queue = album.tracks
        if shuffled {
            queue.shuffle()
            play(track: queue[0], queue: queue)
        } else {
            let safeIndex = max(0, min(index, queue.count - 1))
            play(track: queue[safeIndex], queue: queue)
        }
    }

    public func playPlaylist(_ playlist: Playlist, startingAt index: Int = 0, shuffled: Bool = false) {
        guard !playlist.tracks.isEmpty else { return }
        var queue = playlist.tracks
        if shuffled {
            queue.shuffle()
            play(track: queue[0], queue: queue)
        } else {
            let safeIndex = max(0, min(index, queue.count - 1))
            play(track: queue[safeIndex], queue: queue)
        }
    }

    private func enrichTrackWithLocalDownload(_ track: Track) -> Track {
        if track.localFileURL != nil { return track }
        if let localURL = libraryStore.localFileURL(for: track.id) {
            var copy = track
            copy.localFileURL = localURL
            copy.isDownloaded = true
            return copy
        }
        return track
    }

    private func handleTrackChanged(_ track: Track, stream: ResolvedStream?) {
        showTranslatedLyrics = false
        currentLyrics = nil

        // Cancel any in-flight chord analysis and check SQLite cache at 0 ms
        chordAnalysisTask?.cancel()
        chordAnalysisTask = nil
        activeChordAnalysisRunId = nil
        activeChordAnalysisTrackId = nil
        activeChordAnalysisSimpleMode = nil
        isAnalyzingChords = false
        chordAnalysisProgress = 0.0
        chordAnalysisStatus = nil
        chordAnalysisError = nil

        let simpleMode = audioEngine.chordSimpleMode
        let targetTrackId = track.id
        if let cached = libraryStore.loadChordTimeline(trackId: targetTrackId),
           cached.simpleMode == simpleMode,
           !cached.isPartial {
            currentChordTimeline = cached
            if cached.beats.isEmpty && cached.duration > 1.0 {
                // Legacy cached timeline without beat-grid: upgrade in background without clearing chords
                Task { @MainActor [weak self] in
                    guard let self, self.audioEngine.currentTrack?.id == targetTrackId else { return }
                    await self.analyzeCurrentTrackChords(force: true)
                }
            }
        } else {
            currentChordTimeline = nil
            Task { @MainActor [weak self] in
                guard let self, self.audioEngine.currentTrack?.id == targetTrackId else { return }
                await self.analyzeCurrentTrackChords(force: false)
            }
        }

        // 1. Update lyrics asynchronously
        fetchLyricsForCurrentTrack(track: track)

        // 2. Extract dynamic 4-color mesh gradient palette from artwork
        extractPalette(for: track.highResArtworkURL ?? track.artworkURL)

        // 3. Update Discord Rich Presence
        let settings = libraryStore.settings
        if settings.discordRPCEnabled {
            Task { [weak self] in
                guard let self else { return }
                await self.discordRPC.updatePresence(
                    track: track,
                    stream: stream,
                    isPlaying: self.audioEngine.isPlaying,
                    elapsed: self.audioEngine.currentTime,
                    duration: max(track.duration, self.audioEngine.duration),
                    settings: settings
                )
                let connected = await self.discordRPC.isConnected
                if self.isDiscordConnected != connected {
                    self.isDiscordConnected = connected
                }
            }
        }
    }

    private func handlePlaybackStateChanged(isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval) {
        let settings = libraryStore.settings
        guard settings.discordRPCEnabled else { return }
        guard let track = audioEngine.currentTrack else {
            Task { await discordRPC.clearPresence() }
            return
        }
        let stream = audioEngine.currentStreamInfo
        Task { [weak self] in
            guard let self else { return }
            await self.discordRPC.updatePresence(
                track: track,
                stream: stream,
                isPlaying: isPlaying,
                elapsed: elapsed,
                duration: max(track.duration, duration),
                settings: settings
            )
            let connected = await self.discordRPC.isConnected
            if self.isDiscordConnected != connected {
                self.isDiscordConnected = connected
            }
        }
    }

    // MARK: - Lyrics Actions

    public func fetchLyricsForCurrentTrack(track: Track? = nil) {
        let target = track ?? audioEngine.currentTrack
        lyricsTask?.cancel()
        guard let target else {
            currentLyrics = nil
            isLoadingLyrics = false
            return
        }

        isLoadingLyrics = true
        let providers = libraryStore.settings.lyricsProvidersOrder
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let doc = await self.lyricsEngine.fetchLyrics(track: target, providerOrder: providers)
            guard !Task.isCancelled else { return }
            if self.audioEngine.currentTrack?.id == target.id {
                self.currentLyrics = doc
                self.isLoadingLyrics = false
            }
        }
    }

    public func toggleLyricsTranslation(targetLang: String = Locale.current.language.languageCode?.identifier ?? "en") {
        if showTranslatedLyrics {
            showTranslatedLyrics = false
            return
        }
        guard let doc = currentLyrics else { return }
        if doc.lines.contains(where: { $0.translatedText != nil }) {
            showTranslatedLyrics = true
            return
        }

        isTranslatingLyrics = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTranslatingLyrics = false }
            do {
                let translated = try await self.lyricsEngine.translateLyrics(document: doc, targetLang: targetLang)
                self.currentLyrics = translated
                self.showTranslatedLyrics = true
            } catch {
                self.showToast("Translation unavailable: \(error.localizedDescription)")
            }
        }
    }

    public func currentLyricsOffsetMs(for trackId: String? = nil) -> Double {
        guard let id = trackId ?? audioEngine.currentTrack?.id else { return 0 }
        return libraryStore.settings.lyricsOffsetMs[id] ?? 0
    }

    public func adjustLyricsOffset(deltaMs: Double, for trackId: String? = nil) {
        guard let id = trackId ?? audioEngine.currentTrack?.id else { return }
        updateSettings { settings in
            let current = settings.lyricsOffsetMs[id] ?? 0
            settings.lyricsOffsetMs[id] = max(-10_000, min(10_000, current + deltaMs))
        }
    }

    // MARK: - Non-Blocking Progressive 3-Tier Chord Analysis

    public func analyzeCurrentTrackChords(force: Bool = false) async {
        guard let track = audioEngine.currentTrack else {
            chordAnalysisTask?.cancel()
            chordAnalysisTask = nil
            activeChordAnalysisRunId = nil
            activeChordAnalysisTrackId = nil
            activeChordAnalysisSimpleMode = nil
            currentChordTimeline = nil
            isAnalyzingChords = false
            chordAnalysisProgress = 0.0
            chordAnalysisStatus = nil
            chordAnalysisError = nil
            return
        }

        let targetTrackId = track.id
        let simpleMode = audioEngine.chordSimpleMode

        if !force {
            if let existingTask = chordAnalysisTask,
               activeChordAnalysisTrackId == targetTrackId,
               activeChordAnalysisSimpleMode == simpleMode {
                await existingTask.value
                return
            }

            if let existing = currentChordTimeline,
               existing.trackId == targetTrackId,
               existing.simpleMode == simpleMode,
               !existing.isPartial,
               (!existing.beats.isEmpty || existing.duration <= 1.0) {
                isAnalyzingChords = false
                chordAnalysisProgress = 1.0
                chordAnalysisStatus = nil
                chordAnalysisError = nil
                return
            }

            if let cached = libraryStore.loadChordTimeline(trackId: targetTrackId),
               cached.simpleMode == simpleMode,
               !cached.isPartial,
               (!cached.beats.isEmpty || cached.duration <= 1.0) {
                currentChordTimeline = cached
                isAnalyzingChords = false
                chordAnalysisProgress = 1.0
                chordAnalysisStatus = nil
                chordAnalysisError = nil
                return
            }
        }

        chordAnalysisTask?.cancel()
        chordAnalysisTask = nil

        let runId = UUID()
        activeChordAnalysisRunId = runId
        activeChordAnalysisTrackId = targetTrackId
        activeChordAnalysisSimpleMode = simpleMode
        if currentChordTimeline?.trackId != targetTrackId {
            currentChordTimeline = nil
        }

        isAnalyzingChords = true
        chordAnalysisProgress = 0.02
        chordAnalysisStatus = "Preparing audio..."
        chordAnalysisError = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeChordAnalysisRunId == runId {
                    self.chordAnalysisTask = nil
                    self.activeChordAnalysisTrackId = nil
                    self.activeChordAnalysisSimpleMode = nil
                }
            }

            let knownDuration: TimeInterval? = {
                let d = max(track.duration, self.audioEngine.duration)
                return (d.isFinite && d > 0) ? d : nil
            }()

            do {
                try Task.checkCancellation()

                // 1. Check if track already has a local or downloaded audio file on disk
                let existingLocalURL: URL? = {
                    if let url = track.localFileURL, FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                    if let url = self.libraryStore.localFileURL(for: track.id),
                       FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                    return nil
                }()

                if let localURL = existingLocalURL {
                    self.chordAnalysisStatus = "Analyzing full beat grid..."
                    self.chordAnalysisProgress = 0.15

                    let timeline = try await ChordTimelineAnalyzer.analyzeAudioFile(
                        at: localURL,
                        trackId: targetTrackId,
                        simpleMode: simpleMode,
                        knownDuration: knownDuration,
                        isPartial: false,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.isAnalyzingChords,
                                      self.activeChordAnalysisRunId == runId,
                                      self.audioEngine.currentTrack?.id == targetTrackId else { return }
                                if self.chordAnalysisStatus != "Analyzing full beat grid..." {
                                    self.chordAnalysisStatus = "Analyzing full beat grid..."
                                }
                                let nextProgress = min(0.99, max(0.15, 0.15 + 0.84 * progress))
                                if abs(nextProgress - self.chordAnalysisProgress) >= 0.02 || nextProgress >= 0.99 {
                                    self.chordAnalysisProgress = nextProgress
                                }
                            }
                        }
                    )

                    try Task.checkCancellation()
                    self.libraryStore.saveChordTimeline(timeline)

                    guard self.activeChordAnalysisRunId == runId,
                          self.audioEngine.currentTrack?.id == targetTrackId else { return }
                    self.currentChordTimeline = timeline
                    self.chordAnalysisProgress = 1.0
                    self.chordAnalysisStatus = nil
                    self.chordAnalysisError = nil
                    self.isAnalyzingChords = false
                    return
                }

                // 2. Resolve compact audio stream (YouTube itag 139 -> 140 via VISIONOS, or direct addon)
                self.chordAnalysisStatus = "Downloading audio..."
                self.chordAnalysisProgress = 0.04

                let activeStream = self.audioEngine.currentStreamInfo
                var resolvedStream: ResolvedStream?

                if !track.videoId.isEmpty && !track.isLocal && track.addonConfigId == nil {
                    do {
                        resolvedStream = try await self.streamResolver.resolveCompactAudioForAnalysis(videoId: track.videoId)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if let active = activeStream, !active.isHLS {
                            resolvedStream = active
                        } else {
                            throw error
                        }
                    }
                } else if let configId = track.addonConfigId, let addonTrackId = track.addonTrackId {
                    if let active = activeStream, !active.isHLS, (active.contentLength ?? 0) <= 25_000_000 {
                        resolvedStream = active
                    } else {
                        resolvedStream = try? await self.addonManager.resolveDirectAddonStream(
                            configId: configId,
                            addonTrackId: addonTrackId,
                            quality: .high
                        )
                        if resolvedStream == nil {
                            resolvedStream = activeStream
                        }
                    }
                } else {
                    resolvedStream = activeStream
                }

                guard let streamToDownload = resolvedStream, !streamToDownload.isHLS else {
                    throw BitChordError.streamUnavailable("No progressive audio stream available for chord analysis.")
                }

                try Task.checkCancellation()
                let effectiveKnownDuration = knownDuration ?? streamToDownload.durationSeconds

                if streamToDownload.url.isFileURL {
                    self.chordAnalysisStatus = "Analyzing full beat grid..."
                    let timeline = try await ChordTimelineAnalyzer.analyzeAudioFile(
                        at: streamToDownload.url,
                        trackId: targetTrackId,
                        simpleMode: simpleMode,
                        knownDuration: effectiveKnownDuration,
                        isPartial: false,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.isAnalyzingChords,
                                      self.activeChordAnalysisRunId == runId,
                                      self.audioEngine.currentTrack?.id == targetTrackId else { return }
                                if self.chordAnalysisStatus != "Analyzing full beat grid..." {
                                    self.chordAnalysisStatus = "Analyzing full beat grid..."
                                }
                                let nextProgress = min(0.99, max(0.15, 0.15 + 0.84 * progress))
                                if abs(nextProgress - self.chordAnalysisProgress) >= 0.02 || nextProgress >= 0.99 {
                                    self.chordAnalysisProgress = nextProgress
                                }
                            }
                        }
                    )

                    try Task.checkCancellation()
                    self.libraryStore.saveChordTimeline(timeline)

                    guard self.activeChordAnalysisRunId == runId,
                          self.audioEngine.currentTrack?.id == targetTrackId else { return }
                    self.currentChordTimeline = timeline
                    self.chordAnalysisProgress = 1.0
                    self.chordAnalysisStatus = nil
                    self.chordAnalysisError = nil
                    self.isAnalyzingChords = false
                    return
                }

                // 3. Progressive 2-pass streaming: Pass 1 fast prefix (~280 KB / 450 KB), Pass 2 full completion
                let ext = Self.analysisFileExtension(for: streamToDownload)
                let fullTempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("soundchord_chord_analysis_\(UUID().uuidString).\(ext)")
                defer {
                    try? FileManager.default.removeItem(at: fullTempURL)
                }

                let (events, delegate, session) = Self.makeAnalysisAudioStream(
                    stream: streamToDownload,
                    destinationURL: fullTempURL,
                    onProgress: { [weak self] dlProgress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.isAnalyzingChords,
                                  self.activeChordAnalysisRunId == runId,
                                  self.audioEngine.currentTrack?.id == targetTrackId else { return }
                            if self.currentChordTimeline?.isPartial != true,
                               self.chordAnalysisStatus != "Downloading audio..." {
                                self.chordAnalysisStatus = "Downloading audio..."
                            }
                            let nextProgress = min(0.55, max(0.05, dlProgress * 0.55))
                            if abs(nextProgress - self.chordAnalysisProgress) >= 0.02 || nextProgress >= 0.54 {
                                self.chordAnalysisProgress = nextProgress
                            }
                        }
                    }
                )
                defer { session.finishTasksAndInvalidate() }

                var didPublishPartial = false
                var didCompleteFull = false

                try await withTaskCancellationHandler {
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .prefixReached(let prefixData):
                            if didPublishPartial || delegate.hasCompletedDownload {
                                continue
                            }
                            let prefixURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("soundchord_chord_prefix_\(UUID().uuidString).\(ext)")
                            defer { try? FileManager.default.removeItem(at: prefixURL) }

                            do {
                                try prefixData.write(to: prefixURL, options: .atomic)
                                let partialTimeline = try await ChordTimelineAnalyzer.analyzeAudioFile(
                                    at: prefixURL,
                                    trackId: targetTrackId,
                                    simpleMode: simpleMode,
                                    knownDuration: effectiveKnownDuration,
                                    isPartial: true
                                )
                                try Task.checkCancellation()
                                if !partialTimeline.segments.isEmpty || !partialTimeline.beats.isEmpty {
                                    guard self.activeChordAnalysisRunId == runId,
                                          self.audioEngine.currentTrack?.id == targetTrackId else { return }
                                    self.currentChordTimeline = partialTimeline
                                    self.chordAnalysisStatus = "Analyzing full beat grid..."
                                    self.chordAnalysisProgress = max(self.chordAnalysisProgress, 0.35)
                                    didPublishPartial = true
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // Prefix lacked enough decoded audio frames; allow 450 KB fallback or Pass 2.
                            }

                        case .completed:
                            try Task.checkCancellation()
                            guard self.activeChordAnalysisRunId == runId,
                                  self.audioEngine.currentTrack?.id == targetTrackId else { return }
                            self.chordAnalysisStatus = "Analyzing full beat grid..."
                            self.chordAnalysisProgress = max(self.chordAnalysisProgress, 0.55)

                            let fullTimeline = try await ChordTimelineAnalyzer.analyzeAudioFile(
                                at: fullTempURL,
                                trackId: targetTrackId,
                                simpleMode: simpleMode,
                                knownDuration: effectiveKnownDuration,
                                isPartial: false,
                                onProgress: { [weak self] progress in
                                    Task { @MainActor [weak self] in
                                        guard let self,
                                              self.isAnalyzingChords,
                                              self.activeChordAnalysisRunId == runId,
                                              self.audioEngine.currentTrack?.id == targetTrackId else { return }
                                        if self.chordAnalysisStatus != "Analyzing full beat grid..." {
                                            self.chordAnalysisStatus = "Analyzing full beat grid..."
                                        }
                                        let nextProgress = min(0.99, max(0.55, 0.55 + 0.44 * progress))
                                        if abs(nextProgress - self.chordAnalysisProgress) >= 0.02 || nextProgress >= 0.99 {
                                            self.chordAnalysisProgress = nextProgress
                                        }
                                    }
                                }
                            )

                            try Task.checkCancellation()
                            self.libraryStore.saveChordTimeline(fullTimeline)

                            guard self.activeChordAnalysisRunId == runId,
                                  self.audioEngine.currentTrack?.id == targetTrackId else { return }
                            self.currentChordTimeline = fullTimeline
                            self.chordAnalysisProgress = 1.0
                            self.chordAnalysisStatus = nil
                            self.chordAnalysisError = nil
                            self.isAnalyzingChords = false
                            didCompleteFull = true
                        }
                    }
                } onCancel: {
                    delegate.cancel()
                }

                if !didCompleteFull,
                   self.activeChordAnalysisRunId == runId,
                   self.audioEngine.currentTrack?.id == targetTrackId {
                    self.isAnalyzingChords = false
                    self.chordAnalysisStatus = nil
                }
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled,
                      self.activeChordAnalysisRunId == runId,
                      self.audioEngine.currentTrack?.id == targetTrackId else { return }
                self.chordAnalysisError = error.localizedDescription
                self.chordAnalysisStatus = nil
                self.isAnalyzingChords = false
            }
        }

        chordAnalysisTask = task
        await task.value
    }

    nonisolated private static func analysisFileExtension(for stream: ResolvedStream) -> String {
        let mime = stream.mimeType.lowercased()
        let codec = stream.codec.lowercased()
        if mime.contains("flac") || codec.contains("flac") { return "flac" }
        if mime.contains("mpeg") || mime.contains("mp3") || codec.contains("mp3") { return "mp3" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("aiff") { return "aiff" }
        if mime.contains("ogg") || codec.contains("vorbis") { return "ogg" }
        return "m4a"
    }

    nonisolated private static func makeAnalysisAudioStream(
        stream: ResolvedStream,
        destinationURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> (AsyncThrowingStream<ProgressiveAudioStreamEvent, Error>, ProgressiveChordAudioDelegate, URLSession) {
        var request = URLRequest(url: stream.url)
        request.timeoutInterval = 90
        for (header, value) in stream.requestHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let delegate = ProgressiveChordAudioDelegate(
            destinationURL: destinationURL,
            expectedContentLength: stream.contentLength,
            onProgress: onProgress
        )
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let events = delegate.startStream(request: request, on: session)
        return (events, delegate, session)
    }

    // MARK: - Settings & Downloads

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var updated = libraryStore.settings
        let previousCookie = updated.ytCookieHeader
        let previousDiscord = updated.discordRPCEnabled
        mutate(&updated)
        libraryStore.saveSettings(updated)
        applyCurrentSettingsToAudioEngine()

        if updated.ytCookieHeader != previousCookie {
            Task { [weak self] in
                guard let self else { return }
                let cookieVal = updated.ytCookieHeader.isEmpty ? nil : updated.ytCookieHeader
                await self.innerTube.setCookie(cookieVal)
                await self.streamResolver.setCookie(cookieVal)
                await self.streamResolver.clearCache()
            }
        }

        if updated.discordRPCEnabled != previousDiscord {
            Task { [weak self] in
                guard let self else { return }
                if updated.discordRPCEnabled {
                    await self.discordRPC.connect()
                    if let track = self.audioEngine.currentTrack {
                        await self.discordRPC.updatePresence(
                            track: track,
                            stream: self.audioEngine.currentStreamInfo,
                            isPlaying: self.audioEngine.isPlaying,
                            elapsed: self.audioEngine.currentTime,
                            duration: max(track.duration, self.audioEngine.duration),
                            settings: updated
                        )
                    }
                } else {
                    await self.discordRPC.clearPresence()
                    await self.discordRPC.disconnect()
                }
                self.isDiscordConnected = await self.discordRPC.isConnected
            }
        }
    }

    private func applyCurrentSettingsToAudioEngine() {
        let s = libraryStore.settings
        audioEngine.setCrossfade(s.crossfadeSeconds)
        audioEngine.applyEQ(enabled: s.eqEnabled, gains: s.eqGains, balance: s.balance)
        audioEngine.setLoudnessNormalization(s.loudnessNormalization)
        audioEngine.setPlaybackRate(s.playbackSpeed)
        audioEngine.setStreamQuality(s.streamQuality)
    }

    public func download(_ track: Track) {
        Task { [weak self] in
            guard let self else { return }
            self.showToast("Downloading \"\(track.title)\"…")
            await self.libraryStore.downloadTrack(track, resolver: self.streamResolver)
        }
    }

    public func deleteDownload(_ track: Track) {
        libraryStore.deleteDownload(trackId: track.id)
        showToast("Removed download \"\(track.title)\"")
    }

    // MARK: - Navigation Helpers

    public func toggleRightDrawer(tab: RightDrawerTab) {
        if showRightDrawer && rightDrawerTab == tab {
            showRightDrawer = false
        } else {
            rightDrawerTab = tab
            showRightDrawer = true
        }
    }

    public func selectSidebar(_ item: SidebarItem) {
        selectedSidebar = item
        navigationPath = NavigationPath()
    }

    public func openDestination(_ destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    // MARK: - Feedback Helpers

    public func showError(_ message: String) {
        errorBanner = message
    }

    public func clearError() {
        errorBanner = nil
    }

    public func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - Artwork Dominant Palette Extraction

    private func extractPalette(for url: URL?) {
        guard let url else {
            artworkPaletteColors = Self.defaultPaletteColors
            lastPaletteArtworkURL = nil
            return
        }
        guard url != lastPaletteArtworkURL else { return }
        lastPaletteArtworkURL = url

        paletteTask?.cancel()
        paletteTask = Task { [weak self] in
            guard let self else { return }
            let colors = await Self.sampleFourColors(from: url)
            guard !Task.isCancelled else { return }
            if let colors, colors.count == 4 {
                withAnimation(.easeInOut(duration: 1.2)) {
                    self.artworkPaletteColors = colors
                }
            }
        }
    }

    nonisolated private static func sampleFourColors(from url: URL) async -> [Color]? {
        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url)
                }.value
            } else {
                let (fetched, _) = try await URLSession.shared.data(from: url)
                data = fetched
            }
            return await Task.detached(priority: .utility) {
                let sourceOptions: [CFString: Any] = [
                    kCGImageSourceShouldCache: false
                ]
                guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                    return nil
                }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    return nil
                }
                return extractQuadrantColors(from: cgImage)
            }.value
        } catch {
            return nil
        }
    }

    nonisolated private static func extractQuadrantColors(from cgImage: CGImage) -> [Color]? {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let quadrants: [(xRange: Range<Int>, yRange: Range<Int>)] = [
            (0..<8, 0..<8),
            (8..<16, 0..<8),
            (0..<8, 8..<16),
            (8..<16, 8..<16)
        ]

        var result: [Color] = []
        for q in quadrants {
            var rSum = 0.0, gSum = 0.0, bSum = 0.0, count = 0.0
            for y in q.yRange {
                for x in q.xRange {
                    let idx = (y * size + x) * 4
                    rSum += Double(pixels[idx]) / 255.0
                    gSum += Double(pixels[idx + 1]) / 255.0
                    bSum += Double(pixels[idx + 2]) / 255.0
                    count += 1
                }
            }
            guard count > 0 else { continue }
            var r = rSum / count
            var g = gSum / count
            var b = bSum / count
            // Slightly boost saturation/luminance floor so dark covers stay luminous in the mesh.
            let nsColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            nsColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let boosted = NSColor(
                calibratedHue: h,
                saturation: min(1.0, max(s * 1.25, 0.25)),
                brightness: min(0.85, max(v, 0.22)),
                alpha: 1.0
            )
            r = Double(boosted.redComponent)
            g = Double(boosted.greenComponent)
            b = Double(boosted.blueComponent)
            result.append(Color(red: r, green: g, blue: b))
        }
        return result.count == 4 ? result : nil
    }
}

// MARK: - Progressive Audio Stream Delegate for 2-Pass Chord Analysis

private enum ProgressiveAudioStreamEvent: Sendable {
    case prefixReached(Data)
    case completed(totalBytes: Int64)
}

private final class ProgressiveChordAudioDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let pass1PrimaryThreshold = 280_000
    private static let pass1FallbackThreshold = 450_000
    private static let maxPrefixBufferBytes = 500_000

    private let destinationURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()

    private var expectedContentLength: Int64?
    private var continuation: AsyncThrowingStream<ProgressiveAudioStreamEvent, Error>.Continuation?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var prefixBuffer = Data()
    private var bytesReceived: Int64 = 0
    private var emittedPass1Primary = false
    private var emittedPass1Fallback = false
    private var finishedStream = false
    private var completedDownload = false
    private var lastReportedProgress: Double = -1

    init(
        destinationURL: URL,
        expectedContentLength: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.expectedContentLength = expectedContentLength
        self.onProgress = onProgress
    }

    var hasCompletedDownload: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedDownload
    }

    func startStream(
        request: URLRequest,
        on session: URLSession
    ) -> AsyncThrowingStream<ProgressiveAudioStreamEvent, Error> {
        AsyncThrowingStream { cont in
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            fm.createFile(atPath: destinationURL.path, contents: nil)

            do {
                let handle = try FileHandle(forWritingTo: destinationURL)
                lock.lock()
                self.continuation = cont
                self.fileHandle = handle
                let dataTask = session.dataTask(with: request)
                self.task = dataTask
                lock.unlock()

                cont.onTermination = { [weak self] _ in
                    self?.cancel()
                }
                dataTask.resume()
            } catch {
                cont.finish(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        let activeTask = task
        let handle = fileHandle
        fileHandle = nil
        let cont = finishedStream ? nil : continuation
        continuation = nil
        finishedStream = true
        task = nil
        lock.unlock()

        activeTask?.cancel()
        try? handle?.close()
        cont?.finish(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lock.lock()
            let handle = fileHandle
            fileHandle = nil
            let cont = finishedStream ? nil : continuation
            continuation = nil
            finishedStream = true
            task = nil
            lock.unlock()

            try? handle?.close()
            cont?.finish(throwing: BitChordError.httpError(http.statusCode, "Audio stream returned HTTP \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }

        if response.expectedContentLength > 0 {
            lock.lock()
            expectedContentLength = response.expectedContentLength
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        var progressToEmit: Double?
        var prefixSnapshotToEmit: Data?
        var writeError: Error?

        lock.lock()
        guard !finishedStream else {
            lock.unlock()
            return
        }

        if let handle = fileHandle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                writeError = error
            }
        }

        if writeError == nil {
            if prefixBuffer.count < Self.maxPrefixBufferBytes {
                let remainingCap = Self.maxPrefixBufferBytes - prefixBuffer.count
                prefixBuffer.append(data.prefix(remainingCap))
            }

            bytesReceived += Int64(data.count)
            let expected = expectedContentLength ?? 1_500_000
            if expected > 0 {
                let progress = min(0.99, max(0.01, Double(bytesReceived) / Double(expected)))
                if (progress - lastReportedProgress) >= 0.02 || progress >= 0.98 {
                    lastReportedProgress = progress
                    progressToEmit = progress
                }
            }

            if !emittedPass1Primary && bytesReceived >= Int64(Self.pass1PrimaryThreshold) {
                emittedPass1Primary = true
                prefixSnapshotToEmit = prefixBuffer
            } else if !emittedPass1Fallback && bytesReceived >= Int64(Self.pass1FallbackThreshold) {
                emittedPass1Fallback = true
                prefixSnapshotToEmit = prefixBuffer
            }
        }

        let cont = continuation
        lock.unlock()

        if let writeError {
            failStream(with: writeError)
            dataTask.cancel()
            return
        }

        if let progressToEmit {
            onProgress(progressToEmit)
        }
        if let prefixSnapshotToEmit {
            cont?.yield(.prefixReached(prefixSnapshotToEmit))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        let alreadyFinished = finishedStream
        let cont = alreadyFinished ? nil : continuation
        continuation = nil
        finishedStream = true
        self.task = nil
        let total = bytesReceived
        if error == nil && !alreadyFinished {
            completedDownload = true
        }
        lock.unlock()

        try? handle?.close()
        guard !alreadyFinished else { return }

        if let error {
            cont?.finish(throwing: error)
        } else {
            onProgress(1.0)
            cont?.yield(.completed(totalBytes: total))
            cont?.finish()
        }
    }

    private func failStream(with error: Error) {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        let cont = finishedStream ? nil : continuation
        continuation = nil
        finishedStream = true
        task = nil
        lock.unlock()

        try? handle?.close()
        cont?.finish(throwing: error)
    }
}
