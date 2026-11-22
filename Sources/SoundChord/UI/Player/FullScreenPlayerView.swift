import SwiftUI

public struct FullScreenPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var appColorScheme

    @State private var showAudioControlsPopover = false
    @State private var showStatsPopover = false
    @State private var rightPaneMode: FullScreenRightPane = .lyrics
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isHoveringScrubber = false
    @State private var isHoveringLyricsArea = false

    public init() {}

    private enum FullScreenRightPane {
        case lyrics
        case chords
        case queue
    }

    private var audio: AudioEngine { appState.audioEngine }
    private var track: Track? { audio.currentTrack }

    private var effectiveDuration: TimeInterval {
        max(audio.duration, track?.duration ?? 0)
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : audio.currentTime
    }

    private var progress: Double {
        guard effectiveDuration > 0 else { return 0 }
        return min(1, max(0, displayedTime / effectiveDuration))
    }

    private var offsetSeconds: TimeInterval {
        appState.currentLyricsOffsetMs() / 1000.0
    }

    private var effectiveLyricTime: TimeInterval {
        audio.currentTime + offsetSeconds
    }

    public var body: some View {
        ZStack {
            // Signature 4-color animated artwork mesh backdrop
            MeshGradientBackground(
                colors: appState.artworkPaletteColors,
                isAnimating: audio.isPlaying,
                vignetteOpacity: 0.48
            )

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 34)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)

                GeometryReader { geo in
                    let isWide = geo.size.width >= 900
                    let artSize = min(420, max(240, min(geo.size.height * 0.48, isWide ? geo.size.width * 0.34 : geo.size.width * 0.56)))

                    HStack(alignment: .center, spacing: isWide ? 56 : 28) {
                        leftControlsColumn(artworkSize: artSize)
                            .frame(width: min(440, max(300, artSize + 12)))

                        rightStageColumn(availableWidth: geo.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, isWide ? 64 : 28)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        let darkAccent = SoundChordTheme.accentColor(for: .dark)

        return HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    appState.showFullScreenPlayer = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                    Text("Close")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("Exit Full-Screen Player (Esc)")

            Spacer()

            Button {
                showStatsPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(darkAccent)
                    Text(qualitySummaryPill)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStatsPopover, arrowEdge: .bottom) {
                StatsForNerdsPopoverView()
                    .environmentObject(appState)
                    .environment(\.colorScheme, appColorScheme)
            }
            .help("Stats for Nerds (⌘I)")

            if let remaining = audio.sleepTimerRemaining, remaining > 0 {
                Button {
                    audio.setSleepTimer(minutes: nil)
                    appState.showToast("Sleep timer cancelled")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 11))
                        Text(Track.formatTime(remaining))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(darkAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Click to cancel Sleep Timer")
            }

            Button {
                showAudioControlsPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Audio")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAudioControlsPopover, arrowEdge: .bottom) {
                audioControlsPopover
            }
            .help("Playback Speed, Equalizer and Sleep Timer")

            HStack(spacing: 2) {
                paneToggleButton(icon: "quote.bubble", label: "Lyrics", active: rightPaneMode == .lyrics) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        rightPaneMode = .lyrics
                    }
                }
                paneToggleButton(icon: "guitars", label: "Chords", active: rightPaneMode == .chords) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        rightPaneMode = .chords
                    }
                }
                paneToggleButton(icon: "list.bullet", label: "Up Next", active: rightPaneMode == .queue) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        rightPaneMode = .queue
                    }
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
        }
    }

    private func paneToggleButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(active ? .black : .white.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(active ? Color.white : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Left Column: Artwork + Metadata + Controls

    private func leftControlsColumn(artworkSize: CGFloat) -> some View {
        let darkAccent = SoundChordTheme.accentColor(for: .dark)

        return VStack(spacing: 22) {
            Spacer(minLength: 0)

            ZStack {
                let glowColor = appState.artworkPaletteColors.first ?? darkAccent
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(glowColor.opacity(0.45))
                    .frame(width: artworkSize * 0.90, height: artworkSize * 0.90)
                    .blur(radius: 40)
                    .offset(y: 16)

                ArtworkImage(
                    url: track?.highResArtworkURL ?? track?.artworkURL,
                    size: artworkSize,
                    cornerRadius: 12
                )
                .shadow(color: Color.black.opacity(0.45), radius: 26, x: 0, y: 14)
            }
            .scaleEffect(audio.isPlaying ? 1.0 : 0.94)
            .animation(.spring(response: 0.48, dampingFraction: 0.78), value: audio.isPlaying)

            if let track {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Button {
                            if let artistId = track.artistId, !artistId.isEmpty {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                    appState.showFullScreenPlayer = false
                                }
                                appState.openDestination(.artistId(artistId))
                            }
                        } label: {
                            Text(track.artist)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(track.artistId == nil)
                    }

                    Spacer(minLength: 8)

                    downloadActionButton(for: track)

                    let liked = appState.libraryStore.isLiked(track.id)
                    Button {
                        appState.libraryStore.toggleLike(track)
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(liked ? darkAccent : .white.opacity(0.84))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(liked ? "Unlike" : "Like")
                }
            }

            VStack(spacing: 6) {
                fullScrubberTrack

                HStack {
                    Text(Track.formatTime(displayedTime))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))

                    Spacer()

                    Text("-\(Track.formatTime(max(0, effectiveDuration - displayedTime)))")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            HStack(spacing: 24) {
                Button {
                    audio.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(audio.isShuffled ? darkAccent : .white.opacity(0.72))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await audio.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button {
                    audio.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 56, height: 56)
                            .shadow(color: Color.black.opacity(0.32), radius: 14, y: 6)

                        if audio.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: audio.isPlaying ? 0 : 1.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button {
                    Task { await audio.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button {
                    audio.cycleRepeatMode()
                } label: {
                    Image(systemName: audio.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(audio.repeatMode != .off ? darkAccent : .white.opacity(0.72))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button {
                    audio.toggleMute()
                } label: {
                    Image(systemName: audio.isMuted || audio.volume <= 0.001 ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.70))
                }
                .buttonStyle(.plain)

                CompactVolumeSlider(
                    value: Binding(
                        get: { audio.isMuted ? 0 : Double(audio.volume) },
                        set: { newVal in
                            if audio.isMuted && newVal > 0 {
                                audio.toggleMute()
                            }
                            audio.setVolume(Float(newVal))
                        }
                    ),
                    trackTint: Color.white.opacity(0.22),
                    fillTint: Color.white.opacity(0.92)
                )
                .frame(height: 16)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.70))
            }

            Spacer(minLength: 0)
        }
    }

    private func downloadActionButton(for track: Track) -> some View {
        let activeState = appState.libraryStore.activeDownloads[track.id]
        let isDownloaded = track.isDownloaded || track.isPlayableOffline || appState.libraryStore.localFileURL(for: track.id) != nil

        return Button {
            if isDownloaded {
                appState.deleteDownload(track)
            } else if activeState == nil {
                appState.download(track)
            }
        } label: {
            ZStack {
                if let activeState, activeState.status == .downloading || activeState.status == .queued {
                    ProgressView(value: activeState.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isDownloaded ? SoundChordTheme.darkAccent : .white.opacity(0.84))
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(track.isLocal)
        .help(isDownloaded ? "Downloaded for Offline (click to remove)" : "Download for Offline")
    }

    private var fullScrubberTrack: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let barHeight: CGFloat = (isHoveringScrubber || isScrubbing) ? 7 : 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: barHeight)

                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(0, width * progress), height: barHeight)

                if isHoveringScrubber || isScrubbing {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: Color.black.opacity(0.45), radius: 4, y: 1)
                        .offset(x: max(0, min(width - 13, width * progress - 6.5)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard effectiveDuration > 0 else { return }
                        isScrubbing = true
                        let frac = min(1, max(0, value.location.x / width))
                        scrubTime = frac * effectiveDuration
                    }
                    .onEnded { value in
                        guard effectiveDuration > 0 else {
                            isScrubbing = false
                            return
                        }
                        let frac = min(1, max(0, value.location.x / width))
                        let target = frac * effectiveDuration
                        scrubTime = target
                        audio.seek(to: target)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHoveringScrubber = hovering
            }
        }
    }

    // MARK: - Right Column: Synced Lyrics, Chords or Queue

    @ViewBuilder
    private func rightStageColumn(availableWidth: CGFloat) -> some View {
        switch rightPaneMode {
        case .lyrics:
            fullScreenLyricsPane(availableWidth: availableWidth)
        case .chords:
            fullScreenChordsPane
        case .queue:
            fullScreenQueuePane
        }
    }

    private func fullScreenLyricsPane(availableWidth: CGFloat) -> some View {
        let baseFontSize: CGFloat = availableWidth >= 1320 ? 34 : (availableWidth >= 1040 ? 29 : 26)

        return VStack(spacing: 12) {
            if let doc = appState.currentLyrics, !doc.lines.isEmpty {
                let activeIdx = doc.isSynced ? LyricsSyncHelper.activeLineIndex(in: doc.lines, at: effectiveLyricTime) : nil

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            Spacer().frame(height: 52)

                            ForEach(Array(doc.lines.enumerated()), id: \.element.id) { index, line in
                                let isActive = activeIdx == index
                                let distance = activeIdx.map { abs(index - $0) } ?? 0

                                FullScreenLyricLineView(
                                    line: line,
                                    baseFontSize: baseFontSize,
                                    isSynced: doc.isSynced,
                                    isActive: isActive,
                                    distanceFromActive: distance,
                                    disableBlur: isHoveringLyricsArea,
                                    currentTime: effectiveLyricTime,
                                    showTranslation: appState.showTranslatedLyrics
                                ) {
                                    if doc.isSynced {
                                        audio.seek(to: max(0, line.startTime - offsetSeconds))
                                    }
                                }
                                .id(line.id)
                            }

                            Spacer().frame(height: 140)
                        }
                        .padding(.horizontal, 12)
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.10),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringLyricsArea = hovering
                        }
                    }
                    .onChange(of: activeIdx) { _, newIdx in
                        guard let newIdx, newIdx < doc.lines.count else { return }
                        let targetId = doc.lines[newIdx].id
                        withAnimation(.easeInOut(duration: 0.48)) {
                            proxy.scrollTo(targetId, anchor: UnitPoint(x: 0.5, y: 0.30))
                        }
                    }
                }

                lyricsFooterControls(doc: doc)
            } else if appState.isLoadingLyrics {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading synced lyrics...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("No Lyrics Available")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Tap Retry or switch to Up Next to manage your queue.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.65))
                    if track != nil {
                        Button("Retry Lyrics") {
                            appState.fetchLyricsForCurrentTrack()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.16), in: Capsule())
                        .padding(.top, 4)
                    }
                    Spacer()
                }
            }
        }
    }

    private func lyricsFooterControls(doc: LyricsDocument) -> some View {
        let darkAccent = SoundChordTheme.accentColor(for: .dark)

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: doc.isWordSynced ? "sparkles" : "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(darkAccent)
                Text(doc.provider)
                    .font(.system(size: 11.5, weight: .semibold))
                if doc.isWordSynced {
                    Text("· Word Sync")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12), in: Capsule())

            if doc.isSynced {
                HStack(spacing: 6) {
                    Button("-0.5s") {
                        appState.adjustLyricsOffset(deltaMs: -500)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())

                    Text(LyricsSyncHelper.formatOffset(ms: appState.currentLyricsOffsetMs()))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(abs(offsetSeconds) > 0.01 ? darkAccent : .white.opacity(0.78))
                        .frame(minWidth: 42)

                    Button("+0.5s") {
                        appState.adjustLyricsOffset(deltaMs: 500)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12), in: Capsule())
            }

            Spacer()

            Button {
                appState.toggleLyricsTranslation()
            } label: {
                HStack(spacing: 5) {
                    if appState.isTranslatingLyrics {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                            .tint(appState.showTranslatedLyrics ? .black : .white)
                    } else {
                        Image(systemName: "translate")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(appState.showTranslatedLyrics ? "Translated" : "Translate")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(appState.showTranslatedLyrics ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(appState.showTranslatedLyrics ? darkAccent : Color.white.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .disabled(appState.isTranslatingLyrics)
        }
        .padding(.horizontal, 12)
    }

    private var fullScreenChordsPane: some View {
        let surfaceBg = SoundChordTheme.panelBackground(for: appColorScheme)
        let surfaceStroke = SoundChordTheme.hairline(for: appColorScheme)
        let primary = SoundChordTheme.primaryText(for: appColorScheme)

        return ChordsView(compact: false)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(surfaceBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(surfaceStroke, lineWidth: 1)
            )
            .foregroundStyle(primary)
            .environment(\.colorScheme, appColorScheme)
            .shadow(color: Color.black.opacity(0.28), radius: 18, y: 8)
    }

    private var fullScreenQueuePane: some View {
        let surfaceBg = SoundChordTheme.panelBackground(for: .dark).opacity(0.92)
        let surfaceStroke = SoundChordTheme.hairline(for: .dark)

        return UpNextDrawerContent()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(surfaceBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(surfaceStroke, lineWidth: 1)
            )
    }

    // MARK: - Audio Controls Popover (Speed, Quick EQ, Sleep Timer)

    private var audioControlsPopover: some View {
        let darkAccent = SoundChordTheme.accentColor(for: .dark)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Playback Speed", systemImage: "gauge.with.needle")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(String(format: "%.2fx", appState.libraryStore.settings.playbackSpeed))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(darkAccent)
                }

                Slider(
                    value: Binding(
                        get: { Double(appState.libraryStore.settings.playbackSpeed) },
                        set: { val in
                            let snapped = (val * 20).rounded() / 20
                            appState.updateSettings { $0.playbackSpeed = Float(snapped) }
                        }
                    ),
                    in: 0.5...2.0
                )
                .tint(darkAccent)

                HStack(spacing: 6) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        let selected = abs(Double(appState.libraryStore.settings.playbackSpeed) - speed) < 0.03
                        Button(speed == 1.0 ? "1x" : String(format: "%.2gx", speed)) {
                            appState.updateSettings { $0.playbackSpeed = Float(speed) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? .black : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? darkAccent : Color.primary.opacity(0.08))
                        )
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { appState.libraryStore.settings.eqEnabled },
                    set: { enabled in
                        appState.updateSettings { $0.eqEnabled = enabled }
                    }
                )) {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                        .font(.system(size: 13, weight: .bold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(darkAccent)

                Picker("Preset", selection: Binding(
                    get: { appState.libraryStore.settings.eqPreset },
                    set: { preset in
                        appState.updateSettings {
                            $0.eqEnabled = true
                            $0.eqPreset = preset
                            if preset != .custom {
                                $0.eqGains = preset.gains
                            }
                        }
                    }
                )) {
                    ForEach(EQPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Sleep Timer", systemImage: "moon.zzz")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if let remaining = audio.sleepTimerRemaining, remaining > 0 {
                        Text(Track.formatTime(remaining))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(darkAccent)
                    } else {
                        Text("Off")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    sleepTimerButton("Off", minutes: nil)
                    sleepTimerButton("15m", minutes: 15)
                    sleepTimerButton("30m", minutes: 30)
                    sleepTimerButton("45m", minutes: 45)
                    sleepTimerButton("60m", minutes: 60)
                    Button("End of Track") {
                        let remaining = max(1, effectiveDuration - audio.currentTime)
                        let mins = max(1, Int(ceil(remaining / 60.0)))
                        audio.setSleepTimer(minutes: mins)
                        appState.showToast("Sleep timer set for end of track")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func sleepTimerButton(_ label: String, minutes: Int?) -> some View {
        Button(label) {
            audio.setSleepTimer(minutes: minutes)
            if let minutes {
                appState.showToast("Sleep timer set for \(minutes) min")
            } else {
                appState.showToast("Sleep timer off")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private var qualitySummaryPill: String {
        if let stream = audio.currentStreamInfo {
            return stream.formattedSummary
        }
        if let track {
            if track.isLocal { return "Local Audio" }
            if let q = track.qualityLabel { return q }
        }
        return appState.libraryStore.settings.streamQuality.displayName
    }
}

// MARK: - Apple Music Style Full-Screen Lyric Line

private struct FullScreenLyricLineView: View {
    let line: LyricLine
    let baseFontSize: CGFloat
    let isSynced: Bool
    let isActive: Bool
    let distanceFromActive: Int
    let disableBlur: Bool
    let currentTime: TimeInterval
    let showTranslation: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var lineFontSize: CGFloat {
        line.isBackgroundVocal ? baseFontSize * 0.64 : baseFontSize
    }

    private var blurRadius: CGFloat {
        guard isSynced && !isActive && !disableBlur && !isHovered else { return 0 }
        return min(2.2, CGFloat(distanceFromActive) * 0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            lyricContent
                .font(.system(size: lineFontSize, weight: .bold))
                .italic(line.isBackgroundVocal)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .shadow(
                    color: isActive ? Color.white.opacity(0.28) : .clear,
                    radius: isActive ? 14 : 0
                )

            if showTranslation, let translated = line.translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.system(size: baseFontSize * 0.56, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.80 : 0.42))
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered && isSynced ? Color.white.opacity(0.08) : .clear)
        )
        .scaleEffect(isActive ? 1.03 : 1.0, anchor: .leading)
        .blur(radius: blurRadius)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isActive)
        .animation(.easeOut(duration: 0.2), value: blurRadius)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var lyricContent: some View {
        if isActive && line.isWordSynced {
            Text(
                LyricsSyncHelper.wordSyncedAttributedString(
                    for: line,
                    at: currentTime,
                    activeColor: .white,
                    upcomingColor: Color.white.opacity(0.36)
                )
            )
        } else {
            Text(line.text)
                .foregroundStyle(foregroundColor)
        }
    }

    private var foregroundColor: Color {
        if !isSynced {
            return .white.opacity(0.92)
        }
        if isActive {
            return .white
        }
        if isHovered {
            return .white.opacity(0.84)
        }
        let fade = max(0.26, 0.52 - Double(distanceFromActive) * 0.06)
        return .white.opacity(fade)
    }
}
