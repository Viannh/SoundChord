import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreMedia
import Foundation
import ImageIO
import MediaPlayer
import os

// MARK: - AudioEngine (Dual-Deck AVPlayer + Real-Time 7-Band EQ DSP + MediaPlayer)

@MainActor
public final class AudioEngine: ObservableObject, AudioPlayerProtocol {
    // MARK: - Published State

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isBuffering: Bool = false
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var volume: Float = 0.85
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var isShuffled: Bool = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var playbackRate: Float = 1.0
    @Published public private(set) var crossfadeSeconds: Double = 0
    @Published public private(set) var eqEnabled: Bool = false
    @Published public private(set) var eqGains: [Float] = EQPreset.flat.gains
    @Published public private(set) var balance: Float = 0
    @Published public private(set) var loudnessNormalization: Bool = true
    @Published public private(set) var sleepTimerRemaining: TimeInterval?
    @Published public private(set) var currentStreamInfo: ResolvedStream?
    @Published public private(set) var lastError: String?

    // MARK: - Published Real-Time Chord Detection State

    @Published public private(set) var currentChord: DetectedChord? = nil
    @Published public private(set) var chordHistory: [ChordHistoryEntry] = []
    @Published public private(set) var detectedKey: String? = nil
    @Published public private(set) var chromaVector: [Float] = Array(repeating: 0, count: 12)
    @Published public var chordSimpleMode: Bool = true
    @Published public var chordTransposeSemitones: Int = 0

    // MARK: - Practice Loop & Count-In State

    @Published public var loopRange: ClosedRange<TimeInterval>? = nil
    @Published public var countInEnabled: Bool = false
    @Published public var countInRemaining: Int = 0

    // MARK: - Callbacks

    public var onTrackChanged: ((Track, ResolvedStream?) -> Void)?
    public var onPlaybackStateChanged: ((Bool, TimeInterval, TimeInterval) -> Void)?
    public var onTrackEnded: ((Track, TimeInterval) -> Void)?
    public var onNeedRadioTracks: ((Track) async -> [Track])?
    public var customStreamResolver: ((Track, AudioQuality) async throws -> ResolvedStream?)?

    // MARK: - Dependencies & Dual Decks

    private let streamResolver: StreamResolverProtocol
    private var streamQuality: AudioQuality = .high

    private let decks: [AVPlayer]
    private var activeDeckIndex: Int = 0
    private var activePlayer: AVPlayer { decks[activeDeckIndex] }
    private var standbyDeckIndex: Int { 1 - activeDeckIndex }
    private var standbyPlayer: AVPlayer { decks[standbyDeckIndex] }

    private let dspParams = SharedDSPParameters()
    private let chordDetector = ChordDetector()
    private let chordAnalysisQueue = DispatchQueue(label: "com.soundchord.chord.analysis", qos: .utility)
    private var chordPollTimer: Timer?
    private var chordAnalysisInFlight: Bool = false
    private var chordResetGeneration: UInt64 = 0
    private var nextTapSourceId: UInt64 = 1
    private let maxChordHistoryCount: Int = 80
    private var isLoopSeeking: Bool = false
    private nonisolated(unsafe) var countInTask: Task<Void, Never>?

    // MARK: - Queue & Preload State

    private var originalQueue: [Track] = []
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var radioFetchTask: Task<Void, Never>?
    private var preloaded: PreloadedItem?

    private struct PreloadedItem {
        let track: Track
        let item: AVPlayerItem
        let stream: ResolvedStream?
        let tapSourceId: UInt64
    }

    // MARK: - Crossfade & Sleep Timer

    private var isCrossfading: Bool = false
    private var crossfadeTimer: Timer?
    private var outgoingCrossfadeDeckIndex: Int?

    private var sleepTimer: Timer?
    private var sleepFadeMultiplier: Float = 1.0

    // MARK: - Observers & Listening Accounting

    private var timeObserverToken: Any?
    private weak var timeObserverOwner: AVPlayer?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endOfItemObserver: NSObjectProtocol?
    private var failedItemObserver: NSObjectProtocol?

    private var accumulatedPlaySeconds: TimeInterval = 0
    private var lastTickTimestamp: Date?
    private var hasReportedEndForCurrentTrack: Bool = false
    private var activeAuthoritativeDuration: TimeInterval?
    private var retriedTrackIds: Set<String> = []
    private var hasTriggeredSafetyEndAdvance: Bool = false

    // MARK: - Now Playing & Remote Command State

    private var cachedArtworkTrackId: String?
    private var cachedArtworkURL: URL?
    private var cachedArtworkCGImage: CGImage?
    private var cachedArtworkSize: NSSize = .zero
    private var inFlightArtworkTrackId: String?
    private var artworkFetchTask: Task<Void, Never>?
    private var didSetupRemoteCommands: Bool = false
    private nonisolated(unsafe) var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingSyncDate: Date?

    // MARK: - Init & Deinit

    public init(streamResolver: StreamResolverProtocol) {
        self.streamResolver = streamResolver
        let deckA = AVPlayer()
        let deckB = AVPlayer()
        deckA.automaticallyWaitsToMinimizeStalling = true
        deckB.automaticallyWaitsToMinimizeStalling = true
        deckA.volume = 0.85
        deckB.volume = 0
        self.decks = [deckA, deckB]

        dspParams.update(
            eqEnabled: eqEnabled,
            gains: eqGains,
            balance: balance,
            loudnessNormalization: loudnessNormalization
        )

        attachObservers(to: deckA)
        ensureRemoteCommandsRegistered()
    }

    deinit {
        if let token = timeObserverToken, let owner = timeObserverOwner {
            owner.removeTimeObserver(token)
        }
        if let endOfItemObserver {
            NotificationCenter.default.removeObserver(endOfItemObserver)
        }
        if let failedItemObserver {
            NotificationCenter.default.removeObserver(failedItemObserver)
        }
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        crossfadeTimer?.invalidate()
        sleepTimer?.invalidate()
        chordPollTimer?.invalidate()
        countInTask?.cancel()
    }

    // MARK: - Public Playback Controls

    public func play(track: Track, queue newQueue: [Track]? = nil) async {
        emitTrackEndedIfNeeded()
        cancelCrossfade()
        loadTask?.cancel()
        preloadTask?.cancel()
        preloaded = nil
        lastError = nil

        if let newQueue, !newQueue.isEmpty {
            originalQueue = newQueue
            if isShuffled {
                var remaining = newQueue.filter { $0.id != track.id }
                remaining.shuffle()
                self.queue = [track] + remaining
                self.currentIndex = 0
            } else {
                self.queue = newQueue
                if let idx = newQueue.firstIndex(where: { $0.id == track.id }) {
                    self.currentIndex = idx
                } else {
                    self.queue.insert(track, at: 0)
                    self.originalQueue.insert(track, at: 0)
                    self.currentIndex = 0
                }
            }
        } else {
            if let existingIdx = self.queue.firstIndex(where: { $0.id == track.id }) {
                self.currentIndex = existingIdx
            } else {
                self.queue = [track]
                self.originalQueue = [track]
                self.currentIndex = 0
            }
        }

        await startTrackAtCurrentIndex()
    }

    public func jumpToQueueIndex(_ index: Int) async {
        guard queue.indices.contains(index) else { return }
        emitTrackEndedIfNeeded()
        cancelCrossfade()
        loadTask?.cancel()
        preloadTask?.cancel()
        preloaded = nil
        currentIndex = index
        await startTrackAtCurrentIndex()
    }

    public func togglePlayPause() {
        if countInRemaining > 0 {
            cancelCountIn()
            return
        }
        if isPlaying {
            pause()
        } else {
            playWithOptionalCountIn()
        }
    }

    public func pause() {
        cancelCountIn()
        cancelCrossfade()
        flushPlaySeconds()
        activePlayer.pause()
        isPlaying = false
        isBuffering = false
        updateChordPollingTimer()
        updateNowPlayingInfo()
        onPlaybackStateChanged?(false, currentTime, duration)
    }

    public func resume() {
        cancelCountIn()
        guard let currentTrack else {
            if !queue.isEmpty {
                Task { await startTrackAtCurrentIndex() }
            }
            return
        }

        if activePlayer.currentItem == nil {
            Task { await play(track: currentTrack, queue: queue) }
            return
        }

        // If at end of item, restart from beginning
        if duration > 0 && currentTime >= max(0, duration - 0.3) {
            activePlayer.seek(to: .zero)
            currentTime = 0
            resetChordAnalysis()
        }

        sleepFadeMultiplier = 1.0
        activePlayer.volume = currentEffectiveVolume()
        activePlayer.playImmediately(atRate: playbackRate)
        isPlaying = true
        lastTickTimestamp = Date()
        updateChordPollingTimer()
        updateNowPlayingInfo()
        onPlaybackStateChanged?(true, currentTime, duration)
    }

    // MARK: - Practice Loop & Count-In Controls

    public func setLoopRange(_ range: ClosedRange<TimeInterval>?) {
        isLoopSeeking = false
        guard let range,
              range.lowerBound.isFinite,
              range.upperBound.isFinite else {
            loopRange = nil
            return
        }
        let safeLower = max(0, range.lowerBound)
        let clampedUpper = duration > 0 ? min(duration, range.upperBound) : range.upperBound
        guard clampedUpper > safeLower + 0.1 else {
            loopRange = nil
            return
        }
        loopRange = safeLower...clampedUpper
        invalidatePreloadIfNeeded()
    }

    public func cancelCountIn() {
        countInTask?.cancel()
        countInTask = nil
        if countInRemaining != 0 {
            countInRemaining = 0
        }
    }

    public func playWithOptionalCountIn(bpm: Double? = nil) {
        if isPlaying { return }
        guard countInEnabled else {
            cancelCountIn()
            resume()
            return
        }
        triggerCountIn(bpm: bpm) { [weak self] in
            self?.resume()
        }
    }

    public func triggerCountIn(bpm: Double? = nil, completion: @escaping @MainActor () -> Void) {
        cancelCountIn()
        let effectiveBPM: Double
        if let bpm, bpm.isFinite, bpm > 0 {
            effectiveBPM = max(40.0, min(220.0, bpm))
        } else {
            effectiveBPM = 109.0
        }
        let rate = max(0.5, Double(playbackRate))
        let beatIntervalSec = max(0.25, min(1.25, 60.0 / (effectiveBPM * rate)))
        let stepNs = UInt64(beatIntervalSec * 1_000_000_000)

        countInRemaining = 3
        countInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.countInTask = nil }
            for remaining in [3, 2, 1] {
                guard !Task.isCancelled else {
                    self.countInRemaining = 0
                    return
                }
                self.countInRemaining = remaining
                do {
                    try await Task.sleep(nanoseconds: stepNs)
                } catch {
                    self.countInRemaining = 0
                    return
                }
            }
            guard !Task.isCancelled else {
                self.countInRemaining = 0
                return
            }
            self.countInRemaining = 0
            completion()
        }
    }

    public func next() async {
        await advanceToNext(autoTriggered: false)
    }

    public func previous() async {
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }

        emitTrackEndedIfNeeded()
        cancelCrossfade()
        preloadTask?.cancel()
        preloaded = nil

        if currentIndex > 0 {
            currentIndex -= 1
            await startTrackAtCurrentIndex()
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
            await startTrackAtCurrentIndex()
        } else {
            seek(to: 0)
        }
    }

    public func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        isLoopSeeking = false
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        currentTime = clamped
        resetChordAnalysis()
        updateNowPlayingInfo()
        activePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateNowPlayingInfo()
                self.onPlaybackStateChanged?(self.isPlaying, self.currentTime, self.duration)
            }
        }
    }

    // MARK: - Volume, Speed, Shuffle, Repeat

    public func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        self.volume = clamped
        if clamped > 0 && isMuted {
            isMuted = false
        }
        if !isCrossfading {
            activePlayer.volume = currentEffectiveVolume()
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        if !isCrossfading {
            activePlayer.volume = currentEffectiveVolume()
        }
    }

    public func toggleShuffle() {
        isShuffled.toggle()
        updateRemoteCommandStates()
        guard !queue.isEmpty else { return }

        let activeTrack = queue.indices.contains(currentIndex) ? queue[currentIndex] : currentTrack

        if isShuffled {
            if originalQueue.isEmpty {
                originalQueue = queue
            }
            if let activeTrack {
                var others = queue.filter { $0.id != activeTrack.id }
                others.shuffle()
                queue = [activeTrack] + others
                currentIndex = 0
            } else {
                queue.shuffle()
                currentIndex = 0
            }
        } else {
            if !originalQueue.isEmpty {
                queue = originalQueue
            }
            if let activeTrack, let restoredIndex = queue.firstIndex(where: { $0.id == activeTrack.id }) {
                currentIndex = restoredIndex
            } else {
                currentIndex = min(currentIndex, max(0, queue.count - 1))
            }
        }

        invalidatePreloadIfNeeded()
        updateRemoteCommandStates()
        if currentTrack != nil {
            updateNowPlayingInfo()
        }
    }

    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
        invalidatePreloadIfNeeded()
        updateRemoteCommandStates()
    }

    public func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(2.0, rate))
        playbackRate = clamped
        if isPlaying {
            activePlayer.rate = clamped
        }
        updateNowPlayingInfo()
    }

    // MARK: - DSP: EQ, Balance, Loudness, Crossfade, Stream Quality

    public func applyEQ(enabled: Bool, gains: [Float], balance: Float) {
        eqEnabled = enabled
        if gains.count == EQBand.defaultFrequencies.count {
            eqGains = gains.map { max(-12, min(12, $0)) }
        }
        self.balance = max(-1, min(1, balance))
        dspParams.update(
            eqEnabled: eqEnabled,
            gains: eqGains,
            balance: self.balance,
            loudnessNormalization: loudnessNormalization
        )
    }

    public func setLoudnessNormalization(_ enabled: Bool) {
        loudnessNormalization = enabled
        dspParams.update(
            eqEnabled: eqEnabled,
            gains: eqGains,
            balance: balance,
            loudnessNormalization: loudnessNormalization
        )
    }

    public func setCrossfade(_ seconds: Double) {
        crossfadeSeconds = max(0, min(12, seconds))
    }

    public func setStreamQuality(_ quality: AudioQuality) {
        streamQuality = quality
    }

    // MARK: - Sleep Timer

    public func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepFadeMultiplier = 1.0
        if !isCrossfading {
            activePlayer.volume = currentEffectiveVolume()
        }

        guard let minutes, minutes > 0 else {
            sleepTimerRemaining = nil
            return
        }

        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleepTimerTick()
            }
        }
    }

    private func handleSleepTimerTick() {
        guard let remaining = sleepTimerRemaining else {
            sleepTimer?.invalidate()
            sleepTimer = nil
            return
        }

        let nextRemaining = remaining - 1.0
        if nextRemaining <= 0 {
            sleepTimer?.invalidate()
            sleepTimer = nil
            sleepTimerRemaining = nil
            pause()
            sleepFadeMultiplier = 1.0
            activePlayer.volume = currentEffectiveVolume()
            return
        }

        sleepTimerRemaining = nextRemaining

        // Smooth 5-second fade out before pausing
        if nextRemaining <= 5.0 && isPlaying {
            sleepFadeMultiplier = Float(max(0.05, nextRemaining / 5.0))
            if !isCrossfading {
                activePlayer.volume = currentEffectiveVolume()
            }
        }
    }

    // MARK: - Queue Management

    public func reorderQueue(from source: IndexSet, to destination: Int) {
        guard !queue.isEmpty else { return }
        let playingId = queue.indices.contains(currentIndex) ? queue[currentIndex].id : currentTrack?.id

        var updated = queue
        let moving = source.sorted().compactMap { $0 < updated.count ? updated[$0] : nil }
        for index in source.sorted(by: >) where index < updated.count {
            updated.remove(at: index)
        }
        let removedBeforeDest = source.filter { $0 < destination }.count
        let insertIndex = max(0, min(updated.count, destination - removedBeforeDest))
        updated.insert(contentsOf: moving, at: insertIndex)

        queue = updated
        if !isShuffled {
            originalQueue = updated
        }
        if let playingId, let newIdx = queue.firstIndex(where: { $0.id == playingId }) {
            currentIndex = newIdx
        }
        invalidatePreloadIfNeeded()
    }

    public func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removed = queue.remove(at: index)
        originalQueue.removeAll { $0.id == removed.id }

        if queue.isEmpty {
            clearQueue()
            return
        }

        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            emitTrackEndedIfNeeded()
            currentIndex = min(currentIndex, queue.count - 1)
            Task { await startTrackAtCurrentIndex() }
        }
        invalidatePreloadIfNeeded()
    }

    public func addToQueue(_ track: Track, playNext: Bool) {
        if queue.isEmpty {
            queue = [track]
            originalQueue = [track]
            currentIndex = 0
            return
        }

        if playNext {
            let insertAt = min(currentIndex + 1, queue.count)
            queue.insert(track, at: insertAt)
            if isShuffled {
                originalQueue.append(track)
            } else {
                originalQueue = queue
            }
        } else {
            queue.append(track)
            originalQueue.append(track)
        }
        invalidatePreloadIfNeeded()
    }

    public func clearQueue() {
        cancelCountIn()
        loopRange = nil
        isLoopSeeking = false
        emitTrackEndedIfNeeded()
        cancelCrossfade()
        loadTask?.cancel()
        preloadTask?.cancel()
        radioFetchTask?.cancel()
        preloaded = nil

        for deck in decks {
            deck.pause()
            deck.replaceCurrentItem(with: nil)
        }

        queue = []
        originalQueue = []
        currentTrack = nil
        currentStreamInfo = nil
        currentIndex = 0
        currentTime = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        lastError = nil
        activeAuthoritativeDuration = nil
        retriedTrackIds.removeAll()
        hasTriggeredSafetyEndAdvance = false
        chordDetector.setActiveSource(0)
        resetChordAnalysis()
        updateChordPollingTimer()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        lastNowPlayingSyncDate = nil
        updateRemoteCommandStates()
        onPlaybackStateChanged?(false, 0, 0)
    }

    // MARK: - Track Loading & Deck Activation

    private func startTrackAtCurrentIndex() async {
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]

        cancelCountIn()
        loopRange = nil
        isLoopSeeking = false
        currentTrack = track
        currentTime = 0
        duration = track.duration
        isBuffering = true
        lastError = nil
        accumulatedPlaySeconds = 0
        hasReportedEndForCurrentTrack = false
        lastTickTimestamp = nil
        activeAuthoritativeDuration = nil
        hasTriggeredSafetyEndAdvance = false
        retriedTrackIds.remove(track.id)
        resetChordAnalysis()

        // Fast path: use preloaded item if it matches
        if let preloaded, preloaded.track.id == track.id {
            self.preloaded = nil
            activateItem(
                preloaded.item,
                for: track,
                stream: preloaded.stream,
                tapSourceId: preloaded.tapSourceId,
                onDeck: standbyDeckIndex
            )
            return
        }

        // Publish track metadata immediately while resolving stream (rate = 0 while buffering)
        updateNowPlayingInfo()

        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let (item, stream, tapSourceId) = try await self.preparePlayerItem(for: track)
                guard !Task.isCancelled else { return }
                self.activateItem(
                    item,
                    for: track,
                    stream: stream,
                    tapSourceId: tapSourceId,
                    onDeck: self.activeDeckIndex
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.isBuffering = false
                self.isPlaying = false
                self.lastError = "Unable to play \"\(track.title)\": \(error.localizedDescription)"
                self.updateChordPollingTimer()
                self.updateNowPlayingInfo()
                self.onPlaybackStateChanged?(false, 0, track.duration)
            }
        }
        loadTask = task
        await task.value
    }

    private func activateItem(
        _ item: AVPlayerItem,
        for track: Track,
        stream: ResolvedStream?,
        tapSourceId: UInt64,
        onDeck targetDeckIndex: Int
    ) {
        let previousDeckIndex = activeDeckIndex
        if targetDeckIndex != previousDeckIndex {
            decks[previousDeckIndex].pause()
            decks[previousDeckIndex].replaceCurrentItem(with: nil)
            activeDeckIndex = targetDeckIndex
            attachObservers(to: activePlayer)
        }

        chordDetector.setActiveSource(tapSourceId)
        resetChordAnalysis()

        let player = activePlayer
        player.replaceCurrentItem(with: item)
        observeItemStatus(item)

        let authoritativeDur = stream?.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let isLocalAsset = (track.localFileURL != nil) && FileManager.default.fileExists(atPath: track.localFileURL?.path ?? "")

        currentTrack = track
        currentStreamInfo = stream
        activeAuthoritativeDuration = authoritativeDur
        hasTriggeredSafetyEndAdvance = false
        duration = authoritativeDur ?? track.duration
        currentTime = 0
        isBuffering = !isLocalAsset && item.status != .readyToPlay
        isPlaying = true
        lastError = nil
        sleepFadeMultiplier = 1.0
        accumulatedPlaySeconds = 0
        hasReportedEndForCurrentTrack = false
        lastTickTimestamp = Date()

        player.volume = currentEffectiveVolume()
        player.playImmediately(atRate: playbackRate)

        updateChordPollingTimer()
        onTrackChanged?(track, stream)
        onPlaybackStateChanged?(true, 0, duration)
        updateNowPlayingInfo()
    }

    private func preparePlayerItem(
        for track: Track,
        bypassCustomResolver: Bool = false
    ) async throws -> (AVPlayerItem, ResolvedStream?, UInt64) {
        let asset: AVURLAsset
        let stream: ResolvedStream?

        if let localURL = track.localFileURL, FileManager.default.fileExists(atPath: localURL.path) {
            asset = AVURLAsset(url: localURL)
            stream = ResolvedStream(
                url: localURL,
                mimeType: "audio/\(localURL.pathExtension.lowercased())",
                codec: track.audioCodec ?? localURL.pathExtension.uppercased(),
                bitrateKbps: track.bitrateKbps ?? 0,
                sampleRateHz: track.sampleRateHz,
                bitDepth: track.bitDepth,
                clientName: track.isLocal ? "Local File" : "Downloaded",
                qualityLabel: track.qualityLabel ?? (track.isLocal ? "Local" : "Offline"),
                isHLS: false,
                durationSeconds: track.duration > 0 ? track.duration : nil
            )
        } else {
            let resolved: ResolvedStream
            if !bypassCustomResolver,
               let customResolver = customStreamResolver,
               let customResolved = try await customResolver(track, streamQuality) {
                resolved = customResolved
            } else {
                resolved = try await streamResolver.resolveStream(videoId: track.videoId, quality: streamQuality)
            }

            if resolved.requestHeaders.isEmpty {
                asset = AVURLAsset(url: resolved.url)
            } else {
                asset = AVURLAsset(
                    url: resolved.url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": resolved.requestHeaders]
                )
            }
            stream = resolved
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        // Fix macOS CoreMedia 2x-duration bug on YouTube DASH fragmented audio/mp4 (itag 140/139):
        // set forwardPlaybackEndTime BEFORE activation so playback ends cleanly at the true duration
        // instead of playing dead silence past approxDurationMs and missing AVPlayerItemDidPlayToEndTime.
        if let knownDur = stream?.durationSeconds,
           knownDur.isFinite,
           knownDur > 0,
           !(stream?.isHLS ?? false) {
            item.forwardPlaybackEndTime = CMTime(seconds: knownDur, preferredTimescale: 600)
        }

        // Attach real-time 7-band EQ / balance / loudness + chord detection DSP tap (skip HLS for guaranteed safety)
        let tapSourceId = nextTapSourceId
        nextTapSourceId &+= 1
        if nextTapSourceId == 0 { nextTapSourceId = 1 }

        let isHLS = stream?.isHLS ?? false
        if !isHLS {
            if let mix = await buildAudioMix(
                for: asset,
                params: dspParams,
                chordDetector: chordDetector,
                sourceId: tapSourceId
            ) {
                item.audioMix = mix
            }
        }

        return (item, stream, tapSourceId)
    }

    // MARK: - Next / Radio / Preload / Crossfade

    private func nextQueueIndex(autoTriggered: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }
        if autoTriggered && repeatMode == .one {
            return currentIndex
        }
        if currentIndex + 1 < queue.count {
            return currentIndex + 1
        }
        if repeatMode == .all {
            return 0
        }
        return nil
    }

    private func advanceToNext(autoTriggered: Bool) async {
        guard !queue.isEmpty else { return }

        if autoTriggered, let loop = loopRange {
            isLoopSeeking = true
            let targetTime = loop.lowerBound
            let target = CMTime(seconds: targetTime, preferredTimescale: 600)
            currentTime = targetTime
            resetChordAnalysis()
            await activePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isLoopSeeking = false
            activePlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            lastTickTimestamp = Date()
            updateChordPollingTimer()
            updateNowPlayingInfo()
            onPlaybackStateChanged?(true, targetTime, duration)
            return
        }

        if autoTriggered && repeatMode == .one {
            emitTrackEndedIfNeeded()
            accumulatedPlaySeconds = 0
            hasReportedEndForCurrentTrack = false
            lastTickTimestamp = Date()
            resetChordAnalysis()
            await activePlayer.seek(to: .zero)
            activePlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            updateChordPollingTimer()
            updateNowPlayingInfo()
            onPlaybackStateChanged?(true, 0, duration)
            return
        }

        emitTrackEndedIfNeeded()
        cancelCrossfade()

        if let nextIdx = nextQueueIndex(autoTriggered: autoTriggered) {
            currentIndex = nextIdx
            await startTrackAtCurrentIndex()
            return
        }

        // Queue reached the end with repeatMode == .off -> request radio tracks
        if let seedTrack = currentTrack, let onNeedRadioTracks {
            isBuffering = true
            let radioTracks = await onNeedRadioTracks(seedTrack)
            let existingIds = Set(queue.map(\.id))
            let fresh = radioTracks.filter { !existingIds.contains($0.id) }
            if !fresh.isEmpty {
                queue.append(contentsOf: fresh)
                originalQueue.append(contentsOf: fresh)
                currentIndex += 1
                await startTrackAtCurrentIndex()
                return
            }
        }

        // No more tracks available
        activePlayer.pause()
        isPlaying = false
        isBuffering = false
        updateChordPollingTimer()
        updateNowPlayingInfo()
        onPlaybackStateChanged?(false, currentTime, duration)
    }

    private func preloadNextTrackIfNeeded(remaining: TimeInterval) {
        let preloadLeadTime = max(crossfadeSeconds + 12.0, 15.0)
        guard remaining <= preloadLeadTime else { return }
        guard repeatMode != .one else { return }
        guard let nextIdx = nextQueueIndex(autoTriggered: true),
              queue.indices.contains(nextIdx) else { return }

        let nextTrack = queue[nextIdx]
        if preloaded?.track.id == nextTrack.id || preloadTask != nil {
            return
        }

        preloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.preloadTask = nil }
            if let (item, stream, tapSourceId) = try? await self.preparePlayerItem(for: nextTrack),
               !Task.isCancelled {
                // Only keep if still pointing at the same next track
                if let stillNextIdx = self.nextQueueIndex(autoTriggered: true),
                   self.queue.indices.contains(stillNextIdx),
                   self.queue[stillNextIdx].id == nextTrack.id {
                    self.preloaded = PreloadedItem(
                        track: nextTrack,
                        item: item,
                        stream: stream,
                        tapSourceId: tapSourceId
                    )
                }
            }
        }
    }

    private func invalidatePreloadIfNeeded() {
        guard let preloaded else { return }
        if let nextIdx = nextQueueIndex(autoTriggered: true),
           queue.indices.contains(nextIdx),
           queue[nextIdx].id == preloaded.track.id {
            return
        }
        preloadTask?.cancel()
        preloadTask = nil
        self.preloaded = nil
    }

    private func triggerCrossfadeIfReady(remaining: TimeInterval) {
        guard crossfadeSeconds >= 0.5,
              !isCrossfading,
              isPlaying,
              repeatMode != .one,
              duration > crossfadeSeconds + 2.0,
              remaining <= crossfadeSeconds,
              remaining > 0.25,
              let nextIdx = nextQueueIndex(autoTriggered: true),
              queue.indices.contains(nextIdx) else {
            return
        }

        let nextTrack = queue[nextIdx]
        isCrossfading = true

        Task { [weak self] in
            guard let self else { return }
            let preparedItem: AVPlayerItem
            let preparedStream: ResolvedStream?
            let preparedTapSourceId: UInt64

            if let pre = self.preloaded, pre.track.id == nextTrack.id {
                preparedItem = pre.item
                preparedStream = pre.stream
                preparedTapSourceId = pre.tapSourceId
                self.preloaded = nil
            } else {
                do {
                    let (item, stream, tapSourceId) = try await self.preparePlayerItem(for: nextTrack)
                    preparedItem = item
                    preparedStream = stream
                    preparedTapSourceId = tapSourceId
                } catch {
                    self.isCrossfading = false
                    return
                }
            }

            guard self.isCrossfading, self.isPlaying else {
                self.isCrossfading = false
                return
            }

            let outDeckIdx = self.activeDeckIndex
            let inDeckIdx = self.standbyDeckIndex
            let outPlayer = self.decks[outDeckIdx]
            let inPlayer = self.decks[inDeckIdx]

            self.emitTrackEndedIfNeeded()

            // Pin chord detector to incoming deck before starting playback
            self.chordDetector.setActiveSource(preparedTapSourceId)
            self.resetChordAnalysis()

            // Start incoming deck silently
            inPlayer.replaceCurrentItem(with: preparedItem)
            inPlayer.volume = 0
            inPlayer.playImmediately(atRate: self.playbackRate)

            // Promote incoming deck to active
            self.activeDeckIndex = inDeckIdx
            self.outgoingCrossfadeDeckIndex = outDeckIdx
            self.attachObservers(to: inPlayer)
            self.observeItemStatus(preparedItem)

            self.loopRange = nil
            self.isLoopSeeking = false
            self.currentIndex = nextIdx
            self.currentTrack = nextTrack
            self.currentStreamInfo = preparedStream
            let authDur = preparedStream?.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.activeAuthoritativeDuration = authDur
            self.hasTriggeredSafetyEndAdvance = false
            self.retriedTrackIds.remove(nextTrack.id)
            self.currentTime = 0
            self.duration = authDur ?? nextTrack.duration
            self.accumulatedPlaySeconds = 0
            self.hasReportedEndForCurrentTrack = false
            self.lastTickTimestamp = Date()

            self.updateChordPollingTimer()
            self.onTrackChanged?(nextTrack, preparedStream)
            self.onPlaybackStateChanged?(true, 0, self.duration)
            self.updateNowPlayingInfo()

            let fadeDuration = max(0.4, min(self.crossfadeSeconds, remaining))
            let startDate = Date()

            self.crossfadeTimer?.invalidate()
            self.crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
                Task { @MainActor [weak self] in
                    guard let self else {
                        timer.invalidate()
                        return
                    }
                    let elapsed = Date().timeIntervalSince(startDate)
                    let progress = min(1.0, max(0.0, elapsed / fadeDuration))
                    let effectiveVol = self.currentEffectiveVolume()

                    // True equal-power crossfade curve
                    let outGain = Float(cos(progress * .pi / 2.0)) * effectiveVol
                    let inGain = Float(sin(progress * .pi / 2.0)) * effectiveVol

                    outPlayer.volume = outGain
                    inPlayer.volume = inGain

                    if progress >= 1.0 {
                        timer.invalidate()
                        self.crossfadeTimer = nil
                        outPlayer.pause()
                        outPlayer.replaceCurrentItem(with: nil)
                        outPlayer.volume = 0
                        inPlayer.volume = self.currentEffectiveVolume()
                        self.outgoingCrossfadeDeckIndex = nil
                        self.isCrossfading = false
                    }
                }
            }
        }
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        if let outIdx = outgoingCrossfadeDeckIndex {
            decks[outIdx].pause()
            decks[outIdx].replaceCurrentItem(with: nil)
            decks[outIdx].volume = 0
            outgoingCrossfadeDeckIndex = nil
        }
        isCrossfading = false
        activePlayer.volume = currentEffectiveVolume()
    }

    // MARK: - Player Observers

    private func attachObservers(to player: AVPlayer) {
        if let token = timeObserverToken, let owner = timeObserverOwner {
            owner.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverOwner = nil
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePeriodicTime(time)
            }
        }
        timeObserverOwner = player

        timeControlObservation?.invalidate()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.activePlayer === observed else { return }
                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    if !self.isBuffering {
                        self.isBuffering = true
                        self.updateNowPlayingInfo()
                    }
                case .playing:
                    let wasBuffering = self.isBuffering
                    let wasPlaying = self.isPlaying
                    self.isBuffering = false
                    if !self.isPlaying {
                        self.isPlaying = true
                        self.lastTickTimestamp = Date()
                        self.updateChordPollingTimer()
                    }
                    if wasBuffering || !wasPlaying {
                        self.updateNowPlayingInfo()
                    }
                case .paused:
                    let wasBuffering = self.isBuffering
                    self.isBuffering = false
                    if wasBuffering {
                        self.updateNowPlayingInfo()
                    }
                @unknown default:
                    break
                }
            }
        }

        if let endOfItemObserver {
            NotificationCenter.default.removeObserver(endOfItemObserver)
        }
        endOfItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activePlayer.currentItem === item else { return }
                await self.advanceToNext(autoTriggered: true)
            }
        }

        if let failedItemObserver {
            NotificationCenter.default.removeObserver(failedItemObserver)
        }
        failedItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Playback interrupted."
            Task { @MainActor [weak self] in
                guard let self, self.activePlayer.currentItem === item else { return }
                self.handlePlaybackFailure(for: item, errorMessage: message)
            }
        }
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let errorDesc = observed.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.activePlayer.currentItem === observed else { return }
                switch status {
                case .readyToPlay:
                    if let trackId = self.currentTrack?.id {
                        self.retriedTrackIds.remove(trackId)
                    }
                    if self.activePlayer.timeControlStatus != .waitingToPlayAtSpecifiedRate {
                        self.isBuffering = false
                    }
                    if let effective = self.effectiveDuration(fromItemDuration: CMTimeGetSeconds(observed.duration)) {
                        self.duration = effective
                        self.updateNowPlayingInfo()
                    }
                case .failed:
                    self.handlePlaybackFailure(
                        for: observed,
                        errorMessage: errorDesc ?? "Failed to load audio stream."
                    )
                default:
                    break
                }
            }
        }
    }

    private func effectiveDuration(fromItemDuration itemDuration: TimeInterval) -> TimeInterval? {
        if let auth = activeAuthoritativeDuration, auth.isFinite, auth > 0 {
            if !itemDuration.isFinite || itemDuration <= 0 || itemDuration > auth * 1.35 {
                return auth
            }
            return itemDuration
        }
        guard itemDuration.isFinite && itemDuration > 0 else { return nil }
        return itemDuration
    }

    private func handlePlaybackFailure(for failedItem: AVPlayerItem, errorMessage: String) {
        guard activePlayer.currentItem === failedItem else { return }

        if let track = currentTrack,
           !track.isLocal,
           track.localFileURL == nil,
           !retriedTrackIds.contains(track.id) {
            retriedTrackIds.insert(track.id)
            isBuffering = true
            lastError = nil

            // If an addon lossless substitute failed for a YouTube track, fall back directly to YouTube.
            let wasAddonSubstituteForYouTube = (track.addonConfigId == nil)
                && !track.videoId.isEmpty
                && (currentStreamInfo?.clientName != nil)
                && !(currentStreamInfo?.clientName.hasPrefix("VISIONOS") ?? false)
                && currentStreamInfo?.clientName != "IOS"
                && currentStreamInfo?.clientName != "ANDROID_VR"
                && currentStreamInfo?.clientName != "WEB_REMIX"

            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                if !track.videoId.isEmpty {
                    await self.streamResolver.invalidate(videoId: track.videoId)
                }
                do {
                    let (retryItem, retryStream, retryTapSourceId) = try await self.preparePlayerItem(
                        for: track,
                        bypassCustomResolver: wasAddonSubstituteForYouTube
                    )
                    guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
                    self.activateItem(
                        retryItem,
                        for: track,
                        stream: retryStream,
                        tapSourceId: retryTapSourceId,
                        onDeck: self.activeDeckIndex
                    )
                } catch {
                    guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
                    self.isBuffering = false
                    self.isPlaying = false
                    self.lastError = "Unable to play \"\(track.title)\": \(error.localizedDescription)"
                    self.updateChordPollingTimer()
                    self.updateNowPlayingInfo()
                    self.onPlaybackStateChanged?(false, self.currentTime, self.duration)
                }
            }
            return
        }

        isBuffering = false
        isPlaying = false
        lastError = errorMessage
        updateChordPollingTimer()
        updateNowPlayingInfo()
        onPlaybackStateChanged?(false, currentTime, duration)
    }

    private func handlePeriodicTime(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite && seconds >= 0 {
            if let auth = activeAuthoritativeDuration, auth.isFinite, auth > 0 {
                currentTime = min(seconds, auth)
            } else {
                currentTime = seconds
            }
        }

        if let item = activePlayer.currentItem,
           let itemDuration = effectiveDuration(fromItemDuration: CMTimeGetSeconds(item.duration)),
           abs(itemDuration - duration) > 0.25 {
            duration = itemDuration
            updateNowPlayingInfo()
        }

        if isPlaying {
            if let loop = loopRange, currentTime >= loop.upperBound {
                if !isLoopSeeking {
                    isLoopSeeking = true
                    let targetTime = loop.lowerBound
                    let target = CMTime(seconds: targetTime, preferredTimescale: 600)
                    currentTime = targetTime
                    resetChordAnalysis()
                    updateNowPlayingInfo()
                    activePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.isLoopSeeking = false
                            self.updateNowPlayingInfo()
                            self.onPlaybackStateChanged?(self.isPlaying, self.currentTime, self.duration)
                        }
                    }
                }
                return
            }

            let now = Date()
            if let last = lastTickTimestamp {
                let delta = now.timeIntervalSince(last)
                if delta > 0 && delta < 2.0 {
                    accumulatedPlaySeconds += delta
                }
            }
            lastTickTimestamp = now

            if loopRange == nil,
               !hasTriggeredSafetyEndAdvance,
               let auth = activeAuthoritativeDuration,
               auth > 1.0,
               seconds.isFinite,
               seconds >= auth + 0.35 {
                hasTriggeredSafetyEndAdvance = true
                Task { @MainActor [weak self] in
                    await self?.advanceToNext(autoTriggered: true)
                }
                return
            }

            if loopRange == nil, duration > 0 {
                let remaining = max(0, duration - currentTime)
                preloadNextTrackIfNeeded(remaining: remaining)
                triggerCrossfadeIfReady(remaining: remaining)
            }

            // Gentle periodic elapsed-time resync (every 15s) to prevent Control Center drift
            if !isBuffering,
               let lastSync = lastNowPlayingSyncDate,
               now.timeIntervalSince(lastSync) >= 15.0 {
                updateNowPlayingInfo()
            }
        }
    }

    private func flushPlaySeconds() {
        if isPlaying, let last = lastTickTimestamp {
            let delta = Date().timeIntervalSince(last)
            if delta > 0 && delta < 5.0 {
                accumulatedPlaySeconds += delta
            }
        }
        lastTickTimestamp = nil
    }

    private func emitTrackEndedIfNeeded() {
        flushPlaySeconds()
        guard !hasReportedEndForCurrentTrack, let track = currentTrack else { return }
        hasReportedEndForCurrentTrack = true
        let played = accumulatedPlaySeconds
        if played > 0 {
            onTrackEnded?(track, played)
        }
    }

    private func currentEffectiveVolume() -> Float {
        isMuted ? 0 : max(0, min(1, volume * sleepFadeMultiplier))
    }

    // MARK: - macOS MediaPlayer Integration (Now Playing & Media Keys)

    /// Registers `MPRemoteCommandCenter` handlers on the main actor (safe to call again after `NSApplication` finishes launching).
    public func ensureRemoteCommandsRegistered() {
        let center = MPRemoteCommandCenter.shared()

        if !didSetupRemoteCommands {
            didSetupRemoteCommands = true

            remoteCommandTargets.append((
                center.playCommand,
                center.playCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.resume() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.pauseCommand,
                center.pauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.pause() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.togglePlayPauseCommand,
                center.togglePlayPauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.togglePlayPause() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.stopCommand,
                center.stopCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.pause() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.nextTrackCommand,
                center.nextTrackCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.next() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.previousTrackCommand,
                center.previousTrackCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.previous() }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.changePlaybackPositionCommand,
                center.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    let targetTime = posEvent.positionTime
                    Task { @MainActor [weak self] in self?.seek(to: targetTime) }
                    return .success
                }
            ))

            center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
            remoteCommandTargets.append((
                center.changePlaybackRateCommand,
                center.changePlaybackRateCommand.addTarget { [weak self] event in
                    guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                        return .commandFailed
                    }
                    let targetRate = rateEvent.playbackRate
                    Task { @MainActor [weak self] in self?.setPlaybackRate(targetRate) }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.changeShuffleModeCommand,
                center.changeShuffleModeCommand.addTarget { [weak self] event in
                    guard let shuffleEvent = event as? MPChangeShuffleModeCommandEvent else {
                        return .commandFailed
                    }
                    let desired = shuffleEvent.shuffleType != .off
                    Task { @MainActor [weak self] in
                        guard let self, self.isShuffled != desired else { return }
                        self.toggleShuffle()
                    }
                    return .success
                }
            ))

            remoteCommandTargets.append((
                center.changeRepeatModeCommand,
                center.changeRepeatModeCommand.addTarget { [weak self] event in
                    guard let repeatEvent = event as? MPChangeRepeatModeCommandEvent else {
                        return .commandFailed
                    }
                    let desired: RepeatMode
                    switch repeatEvent.repeatType {
                    case .one: desired = .one
                    case .all: desired = .all
                    case .off: desired = .off
                    @unknown default: desired = .off
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.repeatMode != desired else { return }
                        self.repeatMode = desired
                        self.invalidatePreloadIfNeeded()
                        self.updateRemoteCommandStates()
                    }
                    return .success
                }
            ))
        }

        updateRemoteCommandStates()
        if currentTrack != nil {
            updateNowPlayingInfo()
        }
    }

    /// Clears macOS Now Playing state cleanly on app termination.
    public func shutdownNowPlaying() {
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        inFlightArtworkTrackId = nil
        lastNowPlayingSyncDate = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func updateRemoteCommandStates() {
        let center = MPRemoteCommandCenter.shared()
        let hasTrack = currentTrack != nil || !queue.isEmpty

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = hasTrack
        center.nextTrackCommand.isEnabled = hasTrack
        center.previousTrackCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = hasTrack
        center.changePlaybackRateCommand.isEnabled = hasTrack

        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off

        center.changeRepeatModeCommand.isEnabled = true
        switch repeatMode {
        case .off:
            center.changeRepeatModeCommand.currentRepeatType = .off
        case .all:
            center.changeRepeatModeCommand.currentRepeatType = .all
        case .one:
            center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastNowPlayingSyncDate = nil
            updateRemoteCommandStates()
            return
        }

        let effectiveDuration: TimeInterval
        if duration.isFinite && duration > 0 {
            effectiveDuration = duration
        } else if track.duration.isFinite && track.duration > 0 {
            effectiveDuration = track.duration
        } else {
            effectiveDuration = 0
        }

        let safeElapsed = (currentTime.isFinite && currentTime >= 0) ? currentTime : 0
        let effectiveRate = (isPlaying && !isBuffering) ? Double(playbackRate) : 0.0

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
            MPMediaItemPropertyPersistentID: NSNumber(value: Self.stablePersistentID(for: track.id)),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, currentIndex),
            MPNowPlayingInfoPropertyPlaybackQueueCount: max(1, queue.count)
        ]

        if !track.artist.isEmpty {
            info[MPMediaItemPropertyAlbumArtist] = track.artist
        }
        if let album = track.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let assetURL = currentStreamInfo?.url ?? track.localFileURL {
            info[MPNowPlayingInfoPropertyAssetURL] = assetURL
        }

        if let cgImage = cachedArtworkCGImage,
           cachedArtworkTrackId == track.id,
           cachedArtworkSize.width > 0,
           cachedArtworkSize.height > 0 {
            let naturalSize = cachedArtworkSize
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: naturalSize) { requestedSize in
                let targetSize = (requestedSize.width > 0 && requestedSize.height > 0) ? requestedSize : naturalSize
                return NSImage(cgImage: cgImage, size: targetSize)
            }
        } else if cachedArtworkTrackId != track.id && inFlightArtworkTrackId != track.id {
            fetchNowPlayingArtwork(for: track)
        }

        updateRemoteCommandStates()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        lastNowPlayingSyncDate = Date()
    }

    private func fetchNowPlayingArtwork(for track: Track) {
        artworkFetchTask?.cancel()
        let trackId = track.id

        var candidateURLs: [URL] = []
        if let highRes = track.highResArtworkURL {
            candidateURLs.append(highRes)
        }
        if let base = track.artworkURL, !candidateURLs.contains(base) {
            candidateURLs.append(base)
        }
        let localURL = track.localFileURL

        guard !candidateURLs.isEmpty || localURL != nil else {
            inFlightArtworkTrackId = nil
            return
        }

        inFlightArtworkTrackId = trackId

        artworkFetchTask = Task { [weak self] in
            let fetched: (URL?, CGImage)? = await Task.detached(priority: .utility) {
                for url in candidateURLs {
                    if Task.isCancelled { return nil }
                    let data: Data?
                    if url.isFileURL {
                        data = try? Data(contentsOf: url)
                    } else if let (remoteData, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              !remoteData.isEmpty {
                        data = remoteData
                    } else {
                        data = nil
                    }
                    if let data, let cgImage = Self.decodeCGImage(from: data) {
                        return (url, cgImage)
                    }
                }

                // Fallback: extract embedded artwork from local audio file metadata
                if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
                    let asset = AVURLAsset(url: localURL)
                    if let metadata = try? await asset.load(.commonMetadata) {
                        for item in metadata where item.commonKey == .commonKeyArtwork {
                            if let data = try? await item.load(.dataValue),
                               let cgImage = Self.decodeCGImage(from: data) {
                                return (localURL, cgImage)
                            }
                        }
                    }
                }
                return nil
            }.value

            guard !Task.isCancelled, let self else {
                return
            }
            if self.inFlightArtworkTrackId == trackId {
                self.inFlightArtworkTrackId = nil
            }
            guard let (resolvedURL, cgImage) = fetched else {
                return
            }

            self.cachedArtworkTrackId = trackId
            self.cachedArtworkURL = resolvedURL
            self.cachedArtworkCGImage = cgImage
            self.cachedArtworkSize = NSSize(width: cgImage.width, height: cgImage.height)

            if self.currentTrack?.id == trackId {
                self.updateNowPlayingInfo()
            }
        }
    }

    private nonisolated static func decodeCGImage(from data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           image.width > 0,
           image.height > 0 {
            return image
        }
        return nil
    }

    private nonisolated static func stablePersistentID(for trackId: String) -> UInt64 {
        // Deterministic 64-bit FNV-1a hash so mediaremoted tracks item identity across updates
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in trackId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash == 0 ? 1 : hash
    }

    // MARK: - Real-Time Chord Detection Polling & Reset

    public func resetChordAnalysis() {
        chordResetGeneration &+= 1
        chordDetector.reset()
        currentChord = nil
        chordHistory = []
        detectedKey = nil
        chromaVector = Array(repeating: 0, count: 12)
    }

    private func updateChordPollingTimer() {
        let isHLS = currentStreamInfo?.isHLS ?? false
        let shouldPoll = isPlaying && currentTrack != nil && !isHLS

        if shouldPoll {
            guard chordPollTimer == nil else { return }
            chordPollTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pollChordAnalysis()
                }
            }
        } else {
            chordPollTimer?.invalidate()
            chordPollTimer = nil
        }
    }

    private func pollChordAnalysis() {
        guard isPlaying, !chordAnalysisInFlight, !(currentStreamInfo?.isHLS ?? false) else { return }
        let timestamp = currentTime
        let simpleMode = chordSimpleMode
        let generation = chordResetGeneration
        let detector = chordDetector

        chordAnalysisInFlight = true
        chordAnalysisQueue.async { [weak self] in
            let snapshot = detector.analyze(currentTime: timestamp, simpleMode: simpleMode)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chordAnalysisInFlight = false
                guard self.chordResetGeneration == generation, self.isPlaying else { return }
                self.applyChordSnapshot(snapshot)
            }
        }
    }

    private func applyChordSnapshot(_ snapshot: ChordAnalysisSnapshot) {
        if snapshot.chroma.count == 12 {
            chromaVector = snapshot.chroma
        }
        if snapshot.detectedKey != detectedKey {
            detectedKey = snapshot.detectedKey
        }

        if let chord = snapshot.chord {
            let changedChord = currentChord?.root != chord.root || currentChord?.quality != chord.quality
            if changedChord || abs((currentChord?.confidence ?? 0) - chord.confidence) >= 0.04 {
                currentChord = chord
            }

            let lastEntry = chordHistory.last?.chord
            if lastEntry == nil || lastEntry?.root != chord.root || lastEntry?.quality != chord.quality {
                chordHistory.append(ChordHistoryEntry(chord: chord, timestamp: chord.timestamp))
                if chordHistory.count > maxChordHistoryCount {
                    chordHistory.removeFirst(chordHistory.count - maxChordHistoryCount)
                }
            }
        } else if snapshot.isSilent && currentChord != nil {
            currentChord = nil
        }
    }

    // MARK: - AudioMix + MTAudioProcessingTap Builder

    private func buildAudioMix(
        for asset: AVURLAsset,
        params: SharedDSPParameters,
        chordDetector: ChordDetector,
        sourceId: UInt64
    ) async -> AVMutableAudioMix? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first else {
            return nil
        }

        let context = AudioTapContext(params: params, chordDetector: chordDetector, sourceId: sourceId)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: audioTapInitCallback,
            finalize: audioTapFinalizeCallback,
            prepare: audioTapPrepareCallback,
            unprepare: audioTapUnprepareCallback,
            process: audioTapProcessCallback
        )

        var tapOut: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapOut
        )

        guard status == noErr, let createdTap = tapOut?.takeRetainedValue() else {
            // Tap creation failed: release retained context manually since finalize won't run
            Unmanaged.passUnretained(context).release()
            return nil
        }

        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = createdTap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [inputParams]
        return mix
    }
}

// MARK: - Real-Time DSP Parameters & 7-Band Biquad Processor

private struct DSPConfigSnapshot: Sendable {
    var eqEnabled: Bool = false
    var gains: (Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0)
    var balance: Float = 0
    var loudnessNormalization: Bool = true
    var generation: UInt64 = 0

    func gain(at index: Int) -> Float {
        switch index {
        case 0: return gains.0
        case 1: return gains.1
        case 2: return gains.2
        case 3: return gains.3
        case 4: return gains.4
        case 5: return gains.5
        case 6: return gains.6
        default: return 0
        }
    }
}

private final class SharedDSPParameters: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: DSPConfigSnapshot())

    func update(eqEnabled: Bool, gains: [Float], balance: Float, loudnessNormalization: Bool) {
        lock.withLock { state in
            state.eqEnabled = eqEnabled
            if gains.count >= 7 {
                state.gains = (gains[0], gains[1], gains[2], gains[3], gains[4], gains[5], gains[6])
            }
            state.balance = max(-1, min(1, balance))
            state.loudnessNormalization = loudnessNormalization
            state.generation &+= 1
        }
    }

    func snapshot() -> DSPConfigSnapshot {
        lock.withLock { $0 }
    }
}

private struct BiquadFilter {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
    var isBypass: Bool = true

    // Direct Form II Transposed delay states
    var z1: Double = 0
    var z2: Double = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    mutating func configure(bandIndex: Int, frequency: Double, gainDb: Double, sampleRate: Double) {
        if abs(gainDb) < 0.05 || sampleRate <= 0 {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            isBypass = true
            return
        }

        let clampedFreq = min(max(20.0, frequency), sampleRate * 0.45)
        let A = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * clampedFreq / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        let rb0: Double
        let rb1: Double
        let rb2: Double
        let ra0: Double
        let ra1: Double
        let ra2: Double

        if bandIndex == 0 {
            // Low Shelf (60 Hz)
            let alpha = sinW0 / sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            rb0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha)
            rb1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            rb2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha)
            ra0 = (A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha
            ra1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            ra2 = (A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha
        } else if bandIndex == 6 {
            // High Shelf (15 kHz)
            let alpha = sinW0 / sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            rb0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha)
            rb1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            rb2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha)
            ra0 = (A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha
            ra1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            ra2 = (A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha
        } else {
            // Parametric Peaking EQ (Q = 1.0)
            let alpha = sinW0 / 2.0
            rb0 = 1.0 + alpha * A
            rb1 = -2.0 * cosW0
            rb2 = 1.0 - alpha * A
            ra0 = 1.0 + alpha / A
            ra1 = -2.0 * cosW0
            ra2 = 1.0 - alpha / A
        }

        guard ra0.isFinite && abs(ra0) > 1e-12 else {
            isBypass = true
            return
        }

        b0 = rb0 / ra0
        b1 = rb1 / ra0
        b2 = rb2 / ra0
        a1 = ra1 / ra0
        a2 = ra2 / ra0
        isBypass = false
    }

    @inline(__always)
    mutating func processSample(_ input: Double) -> Double {
        if isBypass { return input }
        let out = b0 * input + z1
        z1 = b1 * input - a1 * out + z2
        z2 = b2 * input - a2 * out
        if !z1.isFinite || !z2.isFinite {
            z1 = 0
            z2 = 0
            return input
        }
        return out
    }
}

private final class AudioTapContext {
    static let bandFrequencies: [Double] = [60, 150, 400, 1_000, 2_400, 6_000, 15_000]
    static let maxChannels = 8

    let params: SharedDSPParameters
    let chordDetector: ChordDetector
    let sourceId: UInt64
    var sampleRate: Double = 44_100
    var channelCount: Int = 2
    var isFloat32: Bool = false
    var isNonInterleaved: Bool = true
    var appliedGeneration: UInt64 = .max

    // [channel][band] pre-allocated in prepare()
    var filters: [[BiquadFilter]] = []

    // Loudness normalization RMS envelope state
    var rmsEnvelope: Double = 0.20
    var currentAgcGain: Double = 1.0

    init(params: SharedDSPParameters, chordDetector: ChordDetector, sourceId: UInt64) {
        self.params = params
        self.chordDetector = chordDetector
        self.sourceId = sourceId
    }

    func prepare(asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        channelCount = min(Self.maxChannels, max(1, Int(asbd.mChannelsPerFrame)))
        isFloat32 = (asbd.mFormatID == kAudioFormatLinearPCM)
            && ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
            && (asbd.mBitsPerChannel == 32)
        isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        filters = (0..<channelCount).map { _ in
            Array(repeating: BiquadFilter(), count: Self.bandFrequencies.count)
        }
        appliedGeneration = .max
        rmsEnvelope = 0.20
        currentAgcGain = 1.0
    }

    func unprepare() {
        for ch in filters.indices {
            for b in filters[ch].indices {
                filters[ch][b].reset()
            }
        }
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isFloat32, frameCount > 0 else { return }

        // Feed live pre-EQ PCM audio into the lock-protected ring buffer with zero heap allocations,
        // even when EQ, balance, and loudness normalization are all bypassed.
        chordDetector.ingestBuffers(
            bufferList,
            frameCount: frameCount,
            isNonInterleaved: isNonInterleaved,
            sampleRate: sampleRate,
            sourceId: sourceId
        )

        guard !filters.isEmpty else { return }

        let config = params.snapshot()
        let needsEQ = config.eqEnabled
        let needsBalance = abs(config.balance) > 0.005
        let needsLoudness = config.loudnessNormalization

        guard needsEQ || needsBalance || needsLoudness else { return }

        if config.generation != appliedGeneration {
            for ch in 0..<filters.count {
                for b in 0..<Self.bandFrequencies.count {
                    filters[ch][b].configure(
                        bandIndex: b,
                        frequency: Self.bandFrequencies[b],
                        gainDb: Double(config.gain(at: b)),
                        sampleRate: sampleRate
                    )
                }
            }
            appliedGeneration = config.generation
        }

        // Stereo balance attenuation: balance < 0 attenuates Right, balance > 0 attenuates Left
        let bal = Double(config.balance)
        let leftGain = bal > 0 ? max(0.0, 1.0 - bal) : 1.0
        let rightGain = bal < 0 ? max(0.0, 1.0 + bal) : 1.0

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        if isNonInterleaved {
            let numChannels = min(buffers.count, filters.count)
            // Compute block RMS for loudness normalization before applying gain
            let agcGain: Double
            if needsLoudness {
                var sumSq = 0.0
                var totalSamples = 0
                for ch in 0..<numChannels {
                    guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let count = min(frameCount, Int(buffers[ch].mDataByteSize) / MemoryLayout<Float>.size)
                    for i in 0..<count {
                        let s = Double(ptr[i])
                        sumSq += s * s
                    }
                    totalSamples += count
                }
                agcGain = updateLoudnessGain(sumSquares: sumSq, sampleCount: totalSamples)
            } else {
                agcGain = 1.0
            }

            for ch in 0..<numChannels {
                guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = min(frameCount, Int(buffers[ch].mDataByteSize) / MemoryLayout<Float>.size)
                let channelBalance = (numChannels >= 2) ? (ch == 0 ? leftGain : (ch == 1 ? rightGain : 1.0)) : 1.0
                let totalGain = agcGain * channelBalance

                for i in 0..<count {
                    var sample = Double(ptr[i])
                    if needsEQ {
                        for b in 0..<7 {
                            sample = filters[ch][b].processSample(sample)
                        }
                    }
                    sample *= totalGain
                    ptr[i] = Float(softLimit(sample))
                }
            }
        } else if let first = buffers.first,
                  let ptr = first.mData?.assumingMemoryBound(to: Float.self) {
            // Interleaved Float32
            let numChannels = min(max(1, Int(first.mNumberChannels)), filters.count)
            let totalFloats = min(frameCount * numChannels, Int(first.mDataByteSize) / MemoryLayout<Float>.size)

            let agcGain: Double
            if needsLoudness {
                var sumSq = 0.0
                for i in 0..<totalFloats {
                    let s = Double(ptr[i])
                    sumSq += s * s
                }
                agcGain = updateLoudnessGain(sumSquares: sumSq, sampleCount: totalFloats)
            } else {
                agcGain = 1.0
            }

            let frames = totalFloats / numChannels
            for frame in 0..<frames {
                let base = frame * numChannels
                for ch in 0..<numChannels {
                    var sample = Double(ptr[base + ch])
                    if needsEQ {
                        for b in 0..<7 {
                            sample = filters[ch][b].processSample(sample)
                        }
                    }
                    let channelBalance = (numChannels >= 2) ? (ch == 0 ? leftGain : (ch == 1 ? rightGain : 1.0)) : 1.0
                    sample *= agcGain * channelBalance
                    ptr[base + ch] = Float(softLimit(sample))
                }
            }
        }
    }

    @inline(__always)
    private func updateLoudnessGain(sumSquares: Double, sampleCount: Int) -> Double {
        guard sampleCount > 0 else { return currentAgcGain }
        let blockRms = sqrt(sumSquares / Double(sampleCount))
        // Ignore silence/noise floor so quiet tails don't pump
        if blockRms > 0.008 {
            rmsEnvelope = rmsEnvelope * 0.96 + blockRms * 0.04
            let targetRms = 0.20 // Approx -14 LUFS playback target
            let desiredGain = min(2.2, max(0.45, targetRms / max(rmsEnvelope, 0.02)))
            currentAgcGain = currentAgcGain * 0.95 + desiredGain * 0.05
        }
        return currentAgcGain
    }

    @inline(__always)
    private func softLimit(_ x: Double) -> Double {
        if x > 0.92 {
            return 0.92 + 0.08 * tanh((x - 0.92) / 0.08)
        } else if x < -0.92 {
            return -0.92 + 0.08 * tanh((x + 0.92) / 0.08)
        }
        return x
    }
}

// MARK: - C-Convention MTAudioProcessingTap Callbacks

private let audioTapInitCallback: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let audioTapFinalizeCallback: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapContext>.fromOpaque(storage).release()
}

private let audioTapPrepareCallback: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.prepare(asbd: processingFormat.pointee)
}

private let audioTapUnprepareCallback: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.unprepare()
}

private let audioTapProcessCallback: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var timeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        &timeRange,
        numberFramesOut
    )
    guard status == noErr else { return }

    let frames = Int(numberFramesOut.pointee)
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.process(bufferList: bufferListInOut, frameCount: frames)
}
