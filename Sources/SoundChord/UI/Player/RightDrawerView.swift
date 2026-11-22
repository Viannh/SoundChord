import SwiftUI
import UniformTypeIdentifiers

public struct RightDrawerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

            switch appState.rightDrawerTab {
            case .queue:
                UpNextDrawerContent()
            case .lyrics:
                LyricsDrawerContent()
            case .chords:
                ChordsView(compact: true)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(SoundChordTheme.panelBackground(for: colorScheme))
        .overlay(alignment: .leading) {
            if colorScheme == .light {
                Rectangle()
                    .fill(SoundChordTheme.hairline(for: .light))
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
        }
    }

    private var headerBar: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let elevated = SoundChordTheme.elevatedBackground(for: colorScheme)

        return HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(RightDrawerTab.allCases) { tab in
                    let selected = appState.rightDrawerTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appState.rightDrawerTab = tab
                        }
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(selected ? primary : secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(elevated)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(cardBg)
            )

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.showRightDrawer = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(secondary)
                    .frame(width: 24, height: 24)
                    .background(cardBg, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close Drawer")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Up Next Queue Content

struct UpNextDrawerContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var draggedTrackIndex: Int?

    private var audio: AudioEngine { appState.audioEngine }

    private var upcomingIndices: [Int] {
        let queue = audio.queue
        guard !queue.isEmpty else { return [] }
        let start = max(0, audio.currentIndex + 1)
        if start < queue.count {
            return Array(start..<queue.count)
        }
        return []
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(alignment: .leading, spacing: 0) {
            if let current = audio.currentTrack {
                nowPlayingCard(current)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                Text("Up Next")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(primary)

                if !upcomingIndices.isEmpty {
                    Text("(\(upcomingIndices.count))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Radio")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(accent.opacity(0.14), in: Capsule())
                .help("Autoplay radio automatically queues similar tracks when Up Next finishes")

                if !audio.queue.isEmpty {
                    Button("Clear") {
                        audio.clearQueue()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if upcomingIndices.isEmpty {
                emptyQueueState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(upcomingIndices, id: \.self) { queueIndex in
                            if queueIndex < audio.queue.count {
                                let item = audio.queue[queueIndex]
                                QueueTrackRow(
                                    track: item,
                                    canMoveUp: queueIndex > audio.currentIndex + 1,
                                    canMoveDown: queueIndex < audio.queue.count - 1,
                                    onPlay: {
                                        appState.play(track: item, queue: audio.queue)
                                    },
                                    onMoveUp: {
                                        audio.reorderQueue(from: IndexSet(integer: queueIndex), to: queueIndex - 1)
                                    },
                                    onMoveDown: {
                                        audio.reorderQueue(from: IndexSet(integer: queueIndex), to: queueIndex + 2)
                                    },
                                    onRemove: {
                                        audio.removeFromQueue(at: queueIndex)
                                    }
                                )
                                .onDrag {
                                    draggedTrackIndex = queueIndex
                                    return NSItemProvider(object: String(queueIndex) as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: QueueDropDelegate(
                                        targetIndex: queueIndex,
                                        draggedIndex: $draggedTrackIndex,
                                        onReorder: { from, to in
                                            audio.reorderQueue(from: IndexSet(integer: from), to: to)
                                        }
                                    )
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func nowPlayingCard(_ track: Track) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return HStack(spacing: 10) {
            ArtworkImage(url: track.artworkURL, size: 42, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    MiniEqualizerBars(isPlaying: audio.isPlaying, tint: accent)
                    Text("NOW PLAYING")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(accent)
                        .tracking(0.5)
                }
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(10)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
    }

    private var emptyQueueState: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(secondary.opacity(0.7))
            Text("Up Next is Empty")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(primary)
            Text("Songs you add to your queue or similar radio tracks will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QueueTrackRow: View {
    let track: Track
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPlay: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)

        return HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                ArtworkImage(url: track.artworkURL, size: 38, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color.black.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -4, y: -4)
                    .help("Remove from Queue")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 0.85 : 0.25)
                    .help("Move Up")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                    .opacity(canMoveDown ? 0.85 : 0.25)
                    .help("Move Down")
                }
            } else if track.duration > 0 {
                Text(track.formattedDuration)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .fill(isHovered ? hoverBg : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

private struct QueueDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let onReorder: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = draggedIndex, source != targetIndex else { return }
        let destination = source < targetIndex ? targetIndex + 1 : targetIndex
        onReorder(source, destination)
        draggedIndex = targetIndex
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Lyrics Drawer Content

private struct LyricsDrawerContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var audio: AudioEngine { appState.audioEngine }

    private var offsetSeconds: TimeInterval {
        appState.currentLyricsOffsetMs() / 1000.0
    }

    private var effectiveTime: TimeInterval {
        audio.currentTime + offsetSeconds
    }

    var body: some View {
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 0) {
            if let doc = appState.currentLyrics, !doc.lines.isEmpty {
                lyricsToolbar(doc: doc)
                Divider().overlay(SoundChordTheme.hairline(for: colorScheme))
                syncedLyricsScroll(doc: doc)
            } else if appState.isLoadingLyrics {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching synced lyrics...")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(secondary)
                    Spacer()
                }
            } else {
                emptyLyricsState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricsToolbar(doc: LyricsDocument) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: doc.isWordSynced ? "sparkles" : (doc.isSynced ? "waveform" : "text.alignleft"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(doc.isSynced ? accent : secondary)
                    Text(doc.provider)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(cardBg, in: Capsule())

                Spacer()

                Button {
                    appState.toggleLyricsTranslation()
                } label: {
                    HStack(spacing: 4) {
                        if appState.isTranslatingLyrics {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "translate")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(appState.showTranslatedLyrics ? "Translated" : "Translate")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(appState.showTranslatedLyrics ? accentFg : primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(appState.showTranslatedLyrics ? accent : cardBg)
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.isTranslatingLyrics)
            }

            if doc.isSynced {
                HStack(spacing: 6) {
                    Text("Sync Offset")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(secondary)

                    Spacer()

                    Button("-0.5s") {
                        appState.adjustLyricsOffset(deltaMs: -500)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Text(LyricsSyncHelper.formatOffset(ms: appState.currentLyricsOffsetMs()))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(abs(offsetSeconds) > 0.01 ? accent : secondary)
                        .frame(minWidth: 44, alignment: .center)

                    Button("+0.5s") {
                        appState.adjustLyricsOffset(deltaMs: 500)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func syncedLyricsScroll(doc: LyricsDocument) -> some View {
        let activeIdx = doc.isSynced ? LyricsSyncHelper.activeLineIndex(in: doc.lines, at: effectiveTime) : nil

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(doc.lines.enumerated()), id: \.element.id) { index, line in
                        let isActive = activeIdx == index
                        let isPast = activeIdx.map { index < $0 } ?? false

                        DrawerLyricLineRow(
                            line: line,
                            isSynced: doc.isSynced,
                            isActive: isActive,
                            isPast: isPast,
                            currentTime: effectiveTime,
                            showTranslation: appState.showTranslatedLyrics
                        ) {
                            if doc.isSynced {
                                audio.seek(to: max(0, line.startTime - offsetSeconds))
                            }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 96)
            }
            .onChange(of: activeIdx) { _, newIndex in
                guard let newIndex, newIndex < doc.lines.count else { return }
                let targetId = doc.lines[newIndex].id
                withAnimation(.easeInOut(duration: 0.42)) {
                    proxy.scrollTo(targetId, anchor: UnitPoint(x: 0.5, y: 0.22))
                }
            }
        }
    }

    private var emptyLyricsState: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(secondary.opacity(0.7))
            Text(audio.currentTrack == nil ? "No Track Playing" : "No Lyrics Available")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(primary)
            Text(
                audio.currentTrack == nil
                    ? "Play a track to see live synced lyrics."
                    : "Synced lyrics were not found across enabled providers."
            )
            .font(.system(size: 12))
            .foregroundStyle(secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if audio.currentTrack != nil {
                Button("Retry") {
                    appState.fetchLyricsForCurrentTrack()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DrawerLyricLineRow: View {
    let line: LyricLine
    let isSynced: Bool
    let isActive: Bool
    let isPast: Bool
    let currentTime: TimeInterval
    let showTranslation: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)

        return VStack(alignment: .leading, spacing: 4) {
            lyricText
                .font(.system(size: line.isBackgroundVocal ? 13 : 16, weight: isActive || !isSynced ? .bold : .semibold))
                .italic(line.isBackgroundVocal)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)

            if showTranslation, let translated = line.translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isActive ? primary.opacity(0.85) : secondary.opacity(0.8))
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .fill(isHovered && isSynced ? hoverBg : .clear)
        )
        .scaleEffect(isActive ? 1.02 : 1.0, anchor: .leading)
        .animation(.easeOut(duration: 0.2), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var lyricText: some View {
        if isActive && line.isWordSynced {
            Text(
                LyricsSyncHelper.wordSyncedAttributedString(
                    for: line,
                    at: currentTime,
                    activeColor: colorScheme == .dark ? .white : SoundChordTheme.lightPrimaryText,
                    upcomingColor: colorScheme == .dark ? Color.white.opacity(0.36) : Color.black.opacity(0.35)
                )
            )
        } else {
            Text(line.text)
                .foregroundStyle(lineColor)
        }
    }

    private var lineColor: Color {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        if !isSynced {
            return primary
        }
        if isActive {
            return primary
        }
        if isHovered {
            return primary.opacity(0.82)
        }
        return isPast ? secondary.opacity(0.65) : secondary
    }
}

// MARK: - Shared Lyrics Synchronization Helper

enum LyricsSyncHelper {
    static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var matched: Int?
        for (idx, line) in lines.enumerated() {
            if line.startTime <= time + 0.08 {
                matched = idx
            } else {
                break
            }
        }
        return matched
    }

    static func formatOffset(ms: Double) -> String {
        let sec = ms / 1000.0
        if abs(sec) < 0.05 { return "0.0s" }
        return String(format: "%+.1fs", sec)
    }

    static func wordSyncedAttributedString(
        for line: LyricLine,
        at time: TimeInterval,
        activeColor: Color,
        upcomingColor: Color
    ) -> AttributedString {
        guard !line.words.isEmpty else {
            var fallback = AttributedString(line.text)
            fallback.foregroundColor = activeColor
            return fallback
        }

        let joinedRaw = line.words.map(\.text).joined()
        let needsInterWordSpace = !line.words.contains(where: { $0.text.hasSuffix(" ") || $0.text.hasPrefix(" ") })
            && joinedRaw.trimmingCharacters(in: .whitespacesAndNewlines) != line.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var output = AttributedString()
        for (idx, word) in line.words.enumerated() {
            let chunkText = (needsInterWordSpace && idx < line.words.count - 1) ? "\(word.text) " : word.text
            var chunk = AttributedString(chunkText)

            if time >= word.endTime && word.endTime > word.startTime {
                chunk.foregroundColor = activeColor
            } else if time >= word.startTime {
                let span = max(0.08, word.endTime - word.startTime)
                let progress = min(1.0, max(0.0, (time - word.startTime) / span))
                chunk.foregroundColor = activeColor.opacity(0.58 + 0.42 * progress)
            } else {
                chunk.foregroundColor = upcomingColor
            }
            output.append(chunk)
        }
        return output
    }
}
