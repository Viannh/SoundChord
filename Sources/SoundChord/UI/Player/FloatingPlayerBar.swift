import SwiftUI

public struct FloatingPlayerBar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHoveringArtwork = false

    public init() {}

    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { SoundChordTheme.accentColor(for: colorScheme) }
    private var primaryText: Color { SoundChordTheme.primaryText(for: colorScheme) }
    private var secondaryText: Color { SoundChordTheme.secondaryText(for: colorScheme) }
    private var audio: AudioEngine { appState.audioEngine }
    private var track: Track? { audio.currentTrack }

    public var body: some View {
        if isDark {
            spotifyDockedBar
        } else {
            appleMusicFloatingCapsule
        }
    }

    // MARK: - Dark Mode: Docked Full-Width Solid #000000 Spotify Bar (ZERO Glass Blur)

    private var spotifyDockedBar: some View {
        HStack(spacing: 16) {
            spotifyLeftTrackInfo
                .frame(minWidth: 210, maxWidth: 290, alignment: .leading)

            Spacer(minLength: 8)

            spotifyCenterTransportAndScrubber
                .frame(maxWidth: 520)

            Spacer(minLength: 8)

            utilityZone
                .frame(minWidth: 210, maxWidth: 290, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(SoundChordTheme.playerBarBackground(for: .dark))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SoundChordTheme.hairline(for: .dark))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var spotifyLeftTrackInfo: some View {
        if let track {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                        appState.showFullScreenPlayer = true
                    }
                } label: {
                    ZStack {
                        ArtworkImage(
                            url: track.artworkURL,
                            size: 52,
                            cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall
                        )

                        if isHoveringArtwork {
                            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall, style: .continuous)
                                .fill(Color.black.opacity(0.45))
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if reduceMotion {
                        isHoveringArtwork = hovering
                    } else {
                        withAnimation(.easeOut(duration: 0.11)) {
                            isHoveringArtwork = hovering
                        }
                    }
                }
                .help("Open Full-Screen Player (⌘⇧F)")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(track.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)

                        if track.isExplicit {
                            Text("E")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(secondaryText)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .fill(Color.white.opacity(0.14))
                                )
                        }
                    }

                    Button {
                        if let artistId = track.artistId, !artistId.isEmpty {
                            appState.openDestination(.artistId(artistId))
                        }
                    } label: {
                        Text(track.artist)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(track.artistId == nil)
                }

                let liked = appState.libraryStore.isLiked(track.id)
                Button {
                    appState.libraryStore.toggleLike(track)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(liked ? accent : secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(liked ? "Remove from Liked Songs" : "Like Song")

                qualityBadgeButton(for: track)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text("SoundChord")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private var spotifyCenterTransportAndScrubber: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                transportIconButton(
                    systemName: "shuffle",
                    size: 13,
                    isActive: audio.isShuffled,
                    help: audio.isShuffled ? "Shuffle On" : "Shuffle Off"
                ) {
                    audio.toggleShuffle()
                }

                transportIconButton(
                    systemName: "backward.fill",
                    size: 15,
                    isDisabled: track == nil,
                    help: "Previous (⌘←)"
                ) {
                    Task { await audio.previous() }
                }

                Button {
                    audio.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(track == nil ? Color.white.opacity(0.28) : Color.white)
                            .frame(width: 34, height: 34)

                        if audio.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                                .tint(.black)
                        } else {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: audio.isPlaying ? 0 : 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
                .help(audio.isPlaying ? "Pause (Space)" : "Play (Space)")

                transportIconButton(
                    systemName: "forward.fill",
                    size: 15,
                    isDisabled: track == nil,
                    help: "Next (⌘→)"
                ) {
                    Task { await audio.next() }
                }

                transportIconButton(
                    systemName: audio.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 13,
                    isActive: audio.repeatMode != .off,
                    help: audio.repeatMode.displayName
                ) {
                    audio.cycleRepeatMode()
                }
            }

            HighRefreshScrubberView(
                anchor: audio.playbackAnchor,
                hasTrack: track != nil,
                fallbackDuration: track?.duration ?? 0,
                style: .spotifyDark,
                onSeek: { target in
                    audio.seek(to: target)
                }
            )
        }
    }

    // MARK: - Light Mode: Apple Music Floating Capsule (Glass #2 and FINAL Glass Surface)

    private var appleMusicFloatingCapsule: some View {
        HStack(spacing: 14) {
            lightTransportZone
            lightLcdZone
            utilityZone
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 760)
        .frame(height: 58)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                SoundChordTheme.lightGlassTint(opacity: appState.libraryStore.settings.glassOpacity)
            }
            .clipShape(Capsule())
        }
        .overlay {
            Capsule()
                .strokeBorder(SoundChordTheme.hairline(for: .light), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(0.15),
            radius: 22,
            x: 0,
            y: 8
        )
    }

    private var lightTransportZone: some View {
        HStack(spacing: 6) {
            transportIconButton(
                systemName: "shuffle",
                size: 12.5,
                isActive: audio.isShuffled,
                help: audio.isShuffled ? "Shuffle On" : "Shuffle Off"
            ) {
                audio.toggleShuffle()
            }

            transportIconButton(
                systemName: "backward.fill",
                size: 14,
                isDisabled: track == nil,
                help: "Previous (⌘←)"
            ) {
                Task { await audio.previous() }
            }

            Button {
                audio.togglePlayPause()
            } label: {
                ZStack {
                    if audio.isBuffering {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .offset(x: audio.isPlaying ? 0 : 1)
                    }
                }
                .foregroundStyle(track == nil ? secondaryText.opacity(0.45) : primaryText)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
            .disabled(track == nil)
            .help(audio.isPlaying ? "Pause (Space)" : "Play (Space)")

            transportIconButton(
                systemName: "forward.fill",
                size: 14,
                isDisabled: track == nil,
                help: "Next (⌘→)"
            ) {
                Task { await audio.next() }
            }

            transportIconButton(
                systemName: audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: 12.5,
                isActive: audio.repeatMode != .off,
                help: audio.repeatMode.displayName
            ) {
                audio.cycleRepeatMode()
            }
        }
        .fixedSize()
    }

    private var lightLcdZone: some View {
        Group {
            if let track {
                HStack(spacing: 10) {
                    // 36pt Artwork - click opens Full-Screen Player
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                            appState.showFullScreenPlayer = true
                        }
                    } label: {
                        ZStack {
                            ArtworkImage(
                                url: track.artworkURL,
                                size: 36,
                                cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall
                            )

                            if isHoveringArtwork {
                                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall, style: .continuous)
                                    .fill(Color.black.opacity(0.45))
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if reduceMotion {
                            isHoveringArtwork = hovering
                        } else {
                            withAnimation(.easeOut(duration: 0.11)) {
                                isHoveringArtwork = hovering
                            }
                        }
                    }
                    .help("Open Full-Screen Player (⌘⇧F)")

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(track.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(primaryText)
                                        .lineLimit(1)

                                    if track.isExplicit {
                                        Text("E")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(secondaryText)
                                            .padding(.horizontal, 3.5)
                                            .padding(.vertical, 1)
                                            .background(
                                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                                    .fill(Color.black.opacity(0.08))
                                            )
                                    }
                                }

                                Button {
                                    if let artistId = track.artistId, !artistId.isEmpty {
                                        appState.openDestination(.artistId(artistId))
                                    }
                                } label: {
                                    Text(track.artist)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(secondaryText)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .disabled(track.artistId == nil)
                            }

                            Spacer(minLength: 4)

                            qualityBadgeButton(for: track)

                            let liked = appState.libraryStore.isLiked(track.id)
                            Button {
                                appState.libraryStore.toggleLike(track)
                            } label: {
                                Image(systemName: liked ? "heart.fill" : "heart")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(liked ? accent : secondaryText)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(liked ? "Remove from Liked Songs" : "Like Song")
                        }

                        HighRefreshScrubberView(
                            anchor: audio.playbackAnchor,
                            hasTrack: true,
                            fallbackDuration: track.duration,
                            style: .appleLight,
                            onSeek: { target in
                                audio.seek(to: target)
                            }
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("SoundChord")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.045))
        )
    }

    private func qualityBadgeButton(for track: Track) -> some View {
        let label = qualityShortBadge(for: track)
        let isLossless = isLosslessStream(for: track)
        return Button {
            appState.showStatsForNerds.toggle()
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(isLossless ? accent : secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(isLossless ? accent.opacity(0.14) : Color.primary.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isLossless ? accent.opacity(0.35) : SoundChordTheme.hairline(for: colorScheme),
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Stats for Nerds (⌘I)")
        .popover(isPresented: $appState.showStatsForNerds, arrowEdge: .top) {
            StatsForNerdsPopoverView()
                .environmentObject(appState)
        }
    }

    // MARK: - Right Zone: Lyrics, Chords, Queue, Volume, Expand

    private var utilityZone: some View {
        HStack(spacing: 6) {
            transportIconButton(
                systemName: "quote.bubble",
                size: 13.5,
                isActive: appState.showRightDrawer && appState.rightDrawerTab == .lyrics,
                help: "Lyrics (⌘L)"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .lyrics)
                }
            }

            transportIconButton(
                systemName: "guitars",
                size: 13.5,
                isActive: appState.showRightDrawer && appState.rightDrawerTab == .chords,
                help: "Chords (⌘K)"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .chords)
                }
            }

            transportIconButton(
                systemName: "list.bullet",
                size: 13.5,
                isActive: appState.showRightDrawer && appState.rightDrawerTab == .queue,
                help: "Up Next (⌘U)"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .queue)
                }
            }

            // Mute + compact volume slider
            HStack(spacing: 5) {
                Button {
                    audio.toggleMute()
                } label: {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .help(audio.isMuted ? "Unmute" : "Mute")

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
                    trackTint: isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.14),
                    fillTint: isDark ? accent : primaryText.opacity(0.82)
                )
                .frame(width: 62, height: 14)
            }

            transportIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                size: 12,
                isDisabled: track == nil,
                help: "Full-Screen Player (⌘⇧F)"
            ) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                    appState.showFullScreenPlayer = true
                }
            }
        }
        .fixedSize()
    }

    // MARK: - Helpers

    private func transportIconButton(
        systemName: String,
        size: CGFloat,
        isActive: Bool = false,
        isDisabled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.16))
                        .frame(width: 26, height: 26)
                }
                Image(systemName: systemName)
                    .font(.system(size: size, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(
                        isDisabled
                            ? secondaryText.opacity(0.35)
                            : (isActive ? accent : primaryText.opacity(0.85))
                    )
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    private var volumeIconName: String {
        if audio.isMuted || audio.volume <= 0.001 {
            return "speaker.slash.fill"
        } else if audio.volume < 0.35 {
            return "speaker.wave.1.fill"
        } else if audio.volume < 0.72 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func qualityShortBadge(for track: Track) -> String {
        if let stream = audio.currentStreamInfo {
            let codec = stream.codec.uppercased()
            if stream.bitrateKbps > 0 {
                return "\(codec) \(stream.bitrateKbps)"
            }
            return stream.qualityLabel.uppercased()
        }
        if let label = track.qualityLabel, !label.isEmpty {
            return label.uppercased()
        }
        if track.isLocal { return "LOCAL" }
        if track.isDownloaded { return "OFFLINE" }
        return appState.libraryStore.settings.streamQuality.displayName.uppercased()
    }

    private func isLosslessStream(for track: Track) -> Bool {
        let codec = (audio.currentStreamInfo?.codec ?? track.audioCodec ?? "").lowercased()
        let label = (audio.currentStreamInfo?.qualityLabel ?? track.qualityLabel ?? "").lowercased()
        return codec.contains("flac") || codec.contains("alac") || label.contains("lossless")
    }
}

// MARK: - High-Refresh Playback Timeline & GPU Scrubber

struct PlaybackTimeline<Content: View>: View {
    let anchor: PlaybackAnchor
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: (TimeInterval) -> Content

    init(
        anchor: PlaybackAnchor,
        isPaused: Bool = false,
        @ViewBuilder content: @escaping (TimeInterval) -> Content
    ) {
        self.anchor = anchor
        self.isPaused = isPaused
        self.content = content
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : nil, paused: isPaused || !anchor.isPlaying)) { _ in
            content(anchor.interpolatedTime())
        }
    }
}

struct HighRefreshScrubberView: View {
    enum Style {
        case spotifyDark
        case appleLight
        case fullScreen
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let anchor: PlaybackAnchor
    let hasTrack: Bool
    let fallbackDuration: TimeInterval
    let style: Style
    let onSeek: (TimeInterval) -> Void

    @State private var isHoveringScrubber = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var effectiveDuration: TimeInterval {
        max(anchor.duration, fallbackDuration)
    }

    var body: some View {
        PlaybackTimeline(anchor: anchor, isPaused: isScrubbing) { liveTime in
            let displayedTime = isScrubbing ? scrubTime : liveTime
            let progress: Double = {
                guard effectiveDuration > 0 else { return 0 }
                return min(1, max(0, displayedTime / effectiveDuration))
            }()

            scrubberLayout(displayedTime: displayedTime, progress: progress)
        }
    }

    @ViewBuilder
    private func scrubberLayout(displayedTime: TimeInterval, progress: Double) -> some View {
        switch style {
        case .spotifyDark:
            let secondary = SoundChordTheme.secondaryText(for: .dark)
            HStack(spacing: 8) {
                Text(hasTrack ? Track.formatTime(displayedTime) : "0:00")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(secondary)
                    .frame(minWidth: 34, alignment: .trailing)

                scrubberTrack(progress: progress)

                Text(hasTrack ? "-\(Track.formatTime(max(0, effectiveDuration - displayedTime)))" : "0:00")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(secondary)
                    .frame(minWidth: 38, alignment: .leading)
            }

        case .appleLight:
            let secondary = SoundChordTheme.secondaryText(for: .light)
            HStack(spacing: 6) {
                Text(Track.formatTime(displayedTime))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(secondary)
                    .frame(minWidth: 28, alignment: .leading)

                scrubberTrack(progress: progress)

                Text("-\(Track.formatTime(max(0, effectiveDuration - displayedTime)))")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

        case .fullScreen:
            VStack(spacing: 6) {
                scrubberTrack(progress: progress)

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
        }
    }

    private func scrubberTrack(progress: Double) -> some View {
        let isActive = isHoveringScrubber || isScrubbing
        let barHeight: CGFloat = {
            switch style {
            case .fullScreen: return isActive ? 7 : 5
            case .spotifyDark, .appleLight: return isActive ? 5 : 3.5
            }
        }()
        let containerHeight: CGFloat = style == .fullScreen ? 16 : 12
        let knobSize: CGFloat = style == .fullScreen ? 13 : 10
        let trackTint: Color = {
            switch style {
            case .fullScreen: return Color.white.opacity(0.22)
            case .spotifyDark: return Color.white.opacity(0.20)
            case .appleLight: return Color.black.opacity(0.14)
            }
        }()
        let fillTint: Color = {
            switch style {
            case .fullScreen:
                return Color.white.opacity(0.95)
            case .spotifyDark:
                return isActive ? SoundChordTheme.accentColor(for: .dark) : Color.white
            case .appleLight:
                return isActive ? SoundChordTheme.accentColor(for: .light) : SoundChordTheme.primaryText(for: .light).opacity(0.78)
            }
        }()

        return GeometryReader { geo in
            let width = max(1, geo.size.width)

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(trackTint)
                    Rectangle()
                        .fill(fillTint)
                        .scaleEffect(x: CGFloat(progress), y: 1.0, anchor: .leading)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())

                if isActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: Color.black.opacity(style == .fullScreen ? 0.45 : 0.35), radius: style == .fullScreen ? 4 : 2, y: 1)
                        .offset(x: max(0, min(width - knobSize, width * progress - knobSize * 0.5)))
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
                        onSeek(target)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: containerHeight)
        .onHover { hovering in
            if reduceMotion {
                isHoveringScrubber = hovering
            } else {
                withAnimation(.easeOut(duration: 0.11)) {
                    isHoveringScrubber = hovering
                }
            }
        }
    }
}

// MARK: - Compact Interactive Volume Slider

struct CompactVolumeSlider: View {
    @Binding var value: Double
    var trackTint: Color = Color.primary.opacity(0.16)
    var fillTint: Color = Color.primary.opacity(0.82)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let clamped = min(1, max(0, value))
            let barHeight: CGFloat = isHovering ? 4.5 : 3

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(trackTint)
                    Rectangle()
                        .fill(fillTint)
                        .scaleEffect(x: CGFloat(clamped), y: 1.0, anchor: .leading)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())

                if isHovering {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: max(0, min(width - 9, width * clamped - 4.5)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = min(1, max(0, drag.location.x / width))
                    }
            )
        }
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.11)) {
                    isHovering = hovering
                }
            }
        }
    }
}

// MARK: - Stats for Nerds Popover (Shared between FloatingPlayerBar & FullScreenPlayerView)

struct StatsForNerdsPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var audio: AudioEngine { appState.audioEngine }
    private var track: Track? { audio.currentTrack }
    private var stream: ResolvedStream? { audio.currentStreamInfo }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Stats for Nerds")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(primary)
                Spacer()
                if let stream {
                    Text(stream.qualityLabel)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.14), in: Capsule())
                }
            }

            Divider()

            if let track {
                VStack(alignment: .leading, spacing: 6) {
                    statRow("Track ID", track.videoId.isEmpty ? track.id : track.videoId, primary: primary, secondary: secondary)
                    statRow("Source", sourceLabel(for: track), primary: primary, secondary: secondary)
                    statRow("Codec", (stream?.codec ?? track.audioCodec ?? "AAC").uppercased(), primary: primary, secondary: secondary)

                    if let kbps = stream?.bitrateKbps ?? track.bitrateKbps, kbps > 0 {
                        statRow("Bitrate", "\(kbps) kbps", primary: primary, secondary: secondary, numeric: true)
                    }

                    if let sampleRate = stream?.sampleRateHz ?? track.sampleRateHz, sampleRate > 0 {
                        statRow("Sample Rate", String(format: "%.1f kHz", Double(sampleRate) / 1000.0), primary: primary, secondary: secondary, numeric: true)
                    }

                    if let bitDepth = stream?.bitDepth ?? track.bitDepth, bitDepth > 0 {
                        statRow("Bit Depth", "\(bitDepth)-bit", primary: primary, secondary: secondary, numeric: true)
                    }

                    if let mime = stream?.mimeType, !mime.isEmpty {
                        statRow("Container", mime, primary: primary, secondary: secondary)
                    }

                    if let client = stream?.clientName, !client.isEmpty {
                        statRow("Stream Client", stream?.isHLS == true ? "\(client) (HLS)" : client, primary: primary, secondary: secondary)
                    }

                    Divider()
                        .padding(.vertical, 2)

                    statRow("Playback Speed", String(format: "%.2fx", audio.playbackRate), primary: primary, secondary: secondary, numeric: true)
                    statRow("Equalizer", audio.eqEnabled ? appState.libraryStore.settings.eqPreset.displayName : "Off", primary: primary, secondary: secondary)
                    statRow("Crossfade", audio.crossfadeSeconds > 0 ? String(format: "%.1fs", audio.crossfadeSeconds) : "Off", primary: primary, secondary: secondary, numeric: true)
                    statRow("Normalization", audio.loudnessNormalization ? "Enabled" : "Off", primary: primary, secondary: secondary)
                }
            } else {
                Text("Start playing a track to inspect live audio stream telemetry.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
            }
        }
        .padding(16)
        .frame(width: 310)
    }

    private func sourceLabel(for track: Track) -> String {
        if track.isLocal { return "Local Library" }
        if track.isDownloaded || track.isPlayableOffline { return "Offline Download" }
        if let source = track.sourceName, !source.isEmpty { return source }
        return "YouTube Music Stream"
    }

    private func statRow(
        _ label: String,
        _ value: String,
        primary: Color,
        secondary: Color,
        numeric: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(numeric ? .system(size: 11.5, weight: .semibold).monospacedDigit() : .system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
