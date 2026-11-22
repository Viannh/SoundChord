import SwiftUI

// MARK: - Chord Studio View (Chordify-Faithful Light & Dark)

public struct ChordsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public let compact: Bool

    @State private var viewMode: ChordViewMode = .chordsOverLyrics
    @State private var diagramsMode: ChordDiagramsSubMode = .animated
    @State private var selectedInstrument: ChordInstrument = .guitar
    @State private var lyricScale: CGFloat = 1.0
    @State private var autoScroll: Bool = true
    @State private var isLoopPickingMode: Bool = false
    @State private var loopPickAnchorBeat: BeatChordCell? = nil

    public init(compact: Bool = false) {
        self.compact = compact
    }

    // MARK: - Local Enums

    enum ChordViewMode: String, CaseIterable, Identifiable {
        case chordsOverLyrics
        case chordDiagrams
        case chordsGrid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chordsOverLyrics: return "Chords over lyrics"
            case .chordDiagrams: return "Chord diagrams"
            case .chordsGrid: return "Chords grid"
            }
        }

        var compactTitle: String {
            switch self {
            case .chordsOverLyrics: return "Lyrics"
            case .chordDiagrams: return "Diagrams"
            case .chordsGrid: return "Grid"
            }
        }
    }

    enum ChordDiagramsSubMode: String, CaseIterable, Identifiable {
        case animated
        case summary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .animated: return "Animated"
            case .summary: return "Summary"
            }
        }
    }

    enum ChordInstrument: String, CaseIterable, Identifiable {
        case guitar
        case piano

        var id: String { rawValue }

        var title: String {
            switch self {
            case .guitar: return "Guitar"
            case .piano: return "Piano"
            }
        }

        var systemImage: String {
            switch self {
            case .guitar: return "guitars"
            case .piano: return "pianokeys"
            }
        }
    }

    // MARK: - Computed Timeline State

    private var audio: AudioEngine { appState.audioEngine }
    private var currentTrack: Track? { audio.currentTrack }
    private var transpose: Int { audio.chordTransposeSemitones }
    private var isHLSStream: Bool { audio.currentStreamInfo?.isHLS == true }

    private var activeTimeline: TrackChordTimeline? {
        guard let track = currentTrack,
              let timeline = appState.currentChordTimeline,
              timeline.trackId == track.id else {
            return nil
        }
        return timeline
    }

    private var effectiveBeatsPerBar: Int {
        max(1, activeTimeline?.beatsPerBar ?? 4)
    }

    private var effectiveBeats: [BeatChordCell] {
        guard let timeline = activeTimeline else { return [] }
        if !timeline.beats.isEmpty {
            return timeline.beats
        }
        return synthesizeFallbackBeats(from: timeline)
    }

    private var activeBeatIndex: Int? {
        let beats = effectiveBeats
        guard !beats.isEmpty else { return nil }
        if let timeline = activeTimeline, !timeline.beats.isEmpty {
            return timeline.beatIndex(at: audio.currentTime)
        }
        let t = max(0, audio.currentTime)
        if let idx = beats.firstIndex(where: { t >= $0.startTime && t < $0.endTime }) {
            return idx
        }
        if let last = beats.last, t >= last.startTime && t <= last.endTime + 0.05 {
            return beats.count - 1
        }
        return nil
    }

    private var activeBeat: BeatChordCell? {
        guard let idx = activeBeatIndex, effectiveBeats.indices.contains(idx) else { return nil }
        return effectiveBeats[idx]
    }

    private var activeSegment: TimedChordSegment? {
        activeTimeline?.segment(at: audio.currentTime)
    }

    private var activeChord: DetectedChord? {
        if let beatChord = activeBeat?.chord {
            return beatChord.transposed(by: transpose)
        }
        if let segChord = activeSegment?.chord {
            return segChord.transposed(by: transpose)
        }
        return audio.currentChord?.transposed(by: transpose)
    }

    private var displayedKey: String? {
        let rawKey = activeTimeline?.key ?? audio.detectedKey
        guard let rawKey, !rawKey.isEmpty else { return nil }
        return transposedKeyDisplay(rawKey)
    }

    private var lyricsOffsetSeconds: TimeInterval {
        guard let trackId = currentTrack?.id else { return 0 }
        return (appState.libraryStore.settings.lyricsOffsetMs[trackId] ?? 0) / 1000.0
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if currentTrack == nil {
                emptyNoTrackState
            } else if isHLSStream {
                hlsUnavailableState
            } else {
                chordWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: currentTrack?.id) { _, _ in
            isLoopPickingMode = false
            loopPickAnchorBeat = nil
        }
        .task(id: currentTrack?.id) {
            guard let track = currentTrack, !isHLSStream else { return }
            if appState.currentChordTimeline?.trackId != track.id
                || appState.currentChordTimeline?.simpleMode != audio.chordSimpleMode {
                await appState.analyzeCurrentTrackChords(force: false)
            }
        }
    }

    private var chordWorkspace: some View {
        let vSpacing: CGFloat = compact ? 8 : 10
        let hPad: CGFloat = compact ? 8 : 4

        return VStack(alignment: .leading, spacing: vSpacing) {
            ChordFeatureToolbar(
                compact: compact,
                selectedInstrument: $selectedInstrument,
                isLoopPickingMode: $isLoopPickingMode,
                bpm: activeTimeline?.bpm,
                displayedKey: displayedKey,
                onToggleQuickLoop: toggleQuickLoop,
                onPickLoopInGrid: {
                    viewMode = .chordsGrid
                    isLoopPickingMode = true
                    loopPickAnchorBeat = nil
                }
            )

            inlineStatusBannerIfNeeded

            viewModeHeaderRow

            if viewMode == .chordsOverLyrics || viewMode == .chordDiagrams {
                LiveBeatStripView(
                    beats: effectiveBeats,
                    beatsPerBar: effectiveBeatsPerBar,
                    activeBeatIndex: activeBeatIndex,
                    currentTime: audio.currentTime,
                    isPlaying: audio.isPlaying,
                    transpose: transpose,
                    loopRange: audio.loopRange,
                    autoScroll: autoScroll,
                    compact: compact,
                    isAnalyzing: appState.isAnalyzingChords,
                    liveFallbackChord: audio.currentChord?.transposed(by: transpose),
                    onSeekBeat: { beat in
                        audio.seek(to: beat.startTime)
                    }
                )
            }

            activeTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, compact ? 8 : 2)
    }

    // MARK: - Non-Blocking Inline Status Strip

    @ViewBuilder
    private var inlineStatusBannerIfNeeded: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        if audio.countInRemaining > 0 {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accentFg)
                Text("Count-in: \(audio.countInRemaining)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(accentFg)
                Spacer()
                Button("Cancel") {
                    audio.cancelCountIn()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentFg.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent))
        } else if isLoopPickingMode {
            HStack(spacing: 8) {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(
                    loopPickAnchorBeat == nil
                        ? "Loop A-B: click start beat in Grid"
                        : "Loop A-B: click end beat in Grid"
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary)
                Spacer()
                Button("Cancel") {
                    isLoopPickingMode = false
                    loopPickAnchorBeat = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardBg))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 1))
        } else if appState.isAnalyzingChords || activeTimeline?.isPartial == true {
            let pct = Int((min(1.0, max(0.0, appState.chordAnalysisProgress)) * 100).rounded())
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
                    .tint(accent)

                Text(activeTimeline?.isPartial == true ? "Refining full beat grid..." : (appState.chordAnalysisStatus ?? "Analyzing full beat grid..."))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)

                Spacer()

                if let live = audio.currentChord?.transposed(by: transpose) {
                    Text("Live: \(live.displayName)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(accent)
                }

                if appState.isAnalyzingChords {
                    Text("\(pct)%")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardBg))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
        } else if let error = appState.chordAnalysisError, !error.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Spacer()
                Button("Retry") {
                    Task { await appState.analyzeCurrentTrackChords(force: true) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accentFg)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(accent))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: - 3-View Switcher Header Row

    private var viewModeHeaderRow: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let elevated = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ChordViewMode.allCases) { mode in
                    let isSelected = viewMode == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            viewMode = mode
                            if mode != .chordsGrid {
                                isLoopPickingMode = false
                                loopPickAnchorBeat = nil
                            }
                        }
                    } label: {
                        Text(compact ? mode.compactTitle : mode.title)
                            .font(.system(size: compact ? 11 : 12, weight: .semibold))
                            .foregroundStyle(isSelected ? accentFg : primary)
                            .padding(.horizontal, compact ? 9 : 12)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? accent : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))

            Spacer(minLength: 4)

            if viewMode == .chordsOverLyrics {
                HStack(spacing: 4) {
                    Button {
                        lyricScale = max(0.80, lyricScale - 0.10)
                    } label: {
                        Text("A-")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardBg))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(lyricScale <= 0.81)
                    .help("Decrease lyric font size")

                    Button {
                        lyricScale = min(1.45, lyricScale + 0.10)
                    } label: {
                        Text("A+")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardBg))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(lyricScale >= 1.44)
                    .help("Increase lyric font size")

                    autoScrollPillButton(accent: accent, accentFg: accentFg, secondary: secondary, cardBg: cardBg, border: border)
                }
            } else if viewMode == .chordDiagrams {
                HStack(spacing: 2) {
                    ForEach(ChordDiagramsSubMode.allCases) { sub in
                        let isSelected = diagramsMode == sub
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                diagramsMode = sub
                            }
                        } label: {
                            Text(sub.title)
                                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                                .foregroundStyle(isSelected ? primary : secondary)
                                .padding(.horizontal, compact ? 7 : 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isSelected ? elevated : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border, lineWidth: 1))
            } else {
                autoScrollPillButton(accent: accent, accentFg: accentFg, secondary: secondary, cardBg: cardBg, border: border)
            }
        }
    }

    private func autoScrollPillButton(
        accent: Color,
        accentFg: Color,
        secondary: Color,
        cardBg: Color,
        border: Color
    ) -> some View {
        Button {
            autoScroll.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: autoScroll ? "location.fill" : "location.slash")
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text("Auto-Scroll")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(autoScroll ? accentFg : secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(autoScroll ? accent : cardBg))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(autoScroll ? "Auto-Scroll On" : "Auto-Scroll Off")
    }

    // MARK: - Active Tab Body

    @ViewBuilder
    private var activeTabContent: some View {
        switch viewMode {
        case .chordsOverLyrics:
            ChordOverLyricsView(
                timeline: activeTimeline,
                beats: effectiveBeats,
                lyrics: appState.currentLyrics,
                isLoadingLyrics: appState.isLoadingLyrics,
                showTranslatedLyrics: appState.showTranslatedLyrics,
                lyricsOffsetSeconds: lyricsOffsetSeconds,
                currentTime: audio.currentTime,
                activeSegmentId: activeSegment?.id,
                transpose: transpose,
                selectedInstrument: selectedInstrument,
                lyricScale: lyricScale,
                autoScroll: autoScroll,
                compact: compact,
                onSeek: { t in audio.seek(to: t) },
                onRetryLyrics: { appState.fetchLyricsForCurrentTrack() },
                onSwitchToGrid: { viewMode = .chordsGrid }
            )

        case .chordDiagrams:
            ChordDiagramsView(
                timeline: activeTimeline,
                diagramsMode: diagramsMode,
                selectedInstrument: selectedInstrument,
                currentTime: audio.currentTime,
                activeSegment: activeSegment,
                activeChord: activeChord,
                transpose: transpose,
                compact: compact,
                onSeek: { t in audio.seek(to: t) }
            )

        case .chordsGrid:
            ChordsGridView(
                timeline: activeTimeline,
                beats: effectiveBeats,
                beatsPerBar: effectiveBeatsPerBar,
                activeBeatIndex: activeBeatIndex,
                currentTime: audio.currentTime,
                isPlaying: audio.isPlaying,
                transpose: transpose,
                loopRange: audio.loopRange,
                isLoopPickingMode: isLoopPickingMode,
                loopPickAnchorBeat: loopPickAnchorBeat,
                autoScroll: autoScroll,
                compact: compact,
                onTapBeat: handleGridBeatTap,
                onReanalyze: {
                    Task { await appState.analyzeCurrentTrackChords(force: true) }
                }
            )
        }
    }

    // MARK: - Actions & Helpers

    private func toggleQuickLoop() {
        if audio.loopRange != nil {
            audio.setLoopRange(nil)
            isLoopPickingMode = false
            loopPickAnchorBeat = nil
            return
        }
        let beats = effectiveBeats
        guard !beats.isEmpty else {
            viewMode = .chordsGrid
            isLoopPickingMode = true
            loopPickAnchorBeat = nil
            return
        }
        let currentIdx = activeBeatIndex ?? 0
        let currentBar = beats[currentIdx].barIndex
        let barBeats = beats.filter { $0.barIndex >= currentBar && $0.barIndex < currentBar + 4 }
        if let first = barBeats.first, let last = barBeats.last {
            audio.setLoopRange(first.startTime...last.endTime)
            isLoopPickingMode = false
            loopPickAnchorBeat = nil
        }
    }

    private func handleGridBeatTap(_ beat: BeatChordCell) {
        if isLoopPickingMode {
            if let anchor = loopPickAnchorBeat {
                let start = min(anchor.startTime, beat.startTime)
                let end = max(anchor.endTime, beat.endTime)
                if end > start {
                    audio.setLoopRange(start...end)
                    audio.seek(to: start)
                }
                loopPickAnchorBeat = nil
                isLoopPickingMode = false
            } else {
                loopPickAnchorBeat = beat
            }
        } else {
            audio.seek(to: beat.startTime)
        }
    }

    private func synthesizeFallbackBeats(from timeline: TrackChordTimeline) -> [BeatChordCell] {
        guard !timeline.segments.isEmpty else { return [] }
        let bpm = max(60.0, min(180.0, timeline.bpm ?? 120.0))
        let beatDur = 60.0 / bpm
        let totalDur = max(timeline.duration, timeline.segments.last?.endTime ?? 0)
        guard totalDur > 0.1 else { return [] }

        let totalBeats = max(1, Int(ceil(totalDur / beatDur)))
        let bpb = max(1, timeline.beatsPerBar)
        var cells: [BeatChordCell] = []
        cells.reserveCapacity(totalBeats)

        var prevKey: String? = nil
        for idx in 0..<totalBeats {
            let start = Double(idx) * beatDur
            let end = min(totalDur, start + beatDur)
            let mid = (start + end) * 0.5
            let segChord = timeline.segment(at: mid)?.chord
            let key = segChord.map { "\($0.root):\($0.quality.rawValue)" }
            let changed = (key != nil && key != prevKey)
            if let key { prevKey = key }

            cells.append(
                BeatChordCell(
                    barIndex: idx / bpb,
                    beatIndex: idx % bpb,
                    chord: segChord,
                    isChordChange: changed,
                    startTime: start,
                    endTime: end
                )
            )
        }
        return cells
    }

    private func transposedKeyDisplay(_ rawKey: String) -> String {
        guard transpose != 0 else { return rawKey }
        let parts = rawKey.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let rootToken = parts.first,
              let rootIdx = DetectedChord.noteNames.firstIndex(of: String(rootToken)) else {
            return rawKey
        }
        let shiftedIdx = ((rootIdx + transpose) % 12 + 12) % 12
        let newRoot = DetectedChord.noteNames[shiftedIdx]
        if parts.count > 1 {
            return "\(newRoot) \(parts[1])"
        }
        return newRoot
    }

    // MARK: - Empty States

    private var emptyNoTrackState: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "guitars")
                .font(.system(size: compact ? 28 : 40, weight: .light))
                .foregroundStyle(secondary.opacity(0.75))
            Text("Chord Studio")
                .font(.system(size: compact ? 15 : 20, weight: .bold))
                .foregroundStyle(primary)
            Text("Play any track to view its beat-synced chords, diagrams, and lyrics.")
                .font(.system(size: compact ? 12 : 13.5))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hlsUnavailableState: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: compact ? 28 : 38, weight: .light))
                .foregroundStyle(secondary.opacity(0.75))
            Text("Chords Unavailable")
                .font(.system(size: compact ? 15 : 19, weight: .bold))
                .foregroundStyle(primary)
            Text("Chord timeline analysis is unavailable on HLS streams.")
                .font(.system(size: compact ? 12 : 13.5))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Chord Symbol Superscript Text

private struct ChordSymbolText: View {
    let chord: DetectedChord
    let rootSize: CGFloat
    let color: Color

    var body: some View {
        let supSize = max(9, rootSize * 0.64)
        let offset = max(3, rootSize * 0.24)
        let sym = chord.quality.symbol

        if sym.isEmpty {
            Text(chord.rootName)
                .font(.system(size: rootSize, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        } else {
            (
                Text(chord.rootName)
                    .font(.system(size: rootSize, weight: .bold, design: .rounded))
                + Text(sym)
                    .font(.system(size: supSize, weight: .bold, design: .rounded))
                    .baselineOffset(offset)
            )
            .foregroundStyle(color)
            .lineLimit(1)
        }
    }
}

// MARK: - 1-Row Bordered Feature Toolbar

private struct ChordFeatureToolbar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    let compact: Bool
    @Binding var selectedInstrument: ChordsView.ChordInstrument
    @Binding var isLoopPickingMode: Bool
    let bpm: Double?
    let displayedKey: String?
    let onToggleQuickLoop: () -> Void
    let onPickLoopInGrid: () -> Void

    private var audio: AudioEngine { appState.audioEngine }
    private var transpose: Int { audio.chordTransposeSemitones }

    var body: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        Group {
            if compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    toolbarRow
                }
            } else {
                toolbarRow
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var toolbarRow: some View {
        let border = SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 0) {
            countInCell
            cellDivider(border)
            instrumentCell
            cellDivider(border)
            loopCell
            cellDivider(border)
            tempoBPMCell
            cellDivider(border)
            capoCell
            cellDivider(border)
            keyCell
            cellDivider(border)
            moreMenuCell
        }
        .frame(height: 34)
    }

    private func cellDivider(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private var countInCell: some View {
        let active = audio.countInEnabled
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)

        return Button {
            audio.countInEnabled.toggle()
        } label: {
            Text("3,2,1")
                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                .foregroundStyle(active ? accentFg : primary)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(active ? accent : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Count-in enabled (click to disable)" : "Enable 3,2,1 count-in")
    }

    private var instrumentCell: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)

        return Menu {
            ForEach(ChordsView.ChordInstrument.allCases) { inst in
                Button {
                    selectedInstrument = inst
                } label: {
                    Label(inst.title, systemImage: inst.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedInstrument.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(selectedInstrument.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(primary)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Switch diagram instrument (Guitar / Piano)")
    }

    private var loopCell: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let isActive = audio.loopRange != nil || isLoopPickingMode

        let loopLabel: String = {
            if isLoopPickingMode {
                return "Pick A-B"
            }
            if let range = audio.loopRange {
                return "\(Track.formatTime(range.lowerBound))-\(Track.formatTime(range.upperBound))"
            }
            return "Off"
        }()

        return HStack(spacing: 0) {
            Button(action: onToggleQuickLoop) {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Loop:")
                        .font(.system(size: 11, weight: .medium))
                    Text(loopLabel)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(isActive ? accentFg : primary)
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(maxHeight: .infinity)
                .background(isActive ? accent : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(audio.loopRange != nil ? "Click to turn Loop Off" : "Loop 4 bars around playhead")

            Menu {
                Button("Loop 4 Bars Here") {
                    onToggleQuickLoop()
                }
                Button("Pick A-B in Chords Grid") {
                    onPickLoopInGrid()
                }
                if audio.loopRange != nil {
                    Divider()
                    Button("Clear Loop") {
                        audio.setLoopRange(nil)
                        isLoopPickingMode = false
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isActive ? accentFg : secondary)
                    .padding(.horizontal, 5)
                    .frame(maxHeight: .infinity)
                    .background(isActive ? accent : Color.clear)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var tempoBPMCell: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)

        let ratePct = Int((Double(audio.playbackRate) * 100.0).rounded())
        let effectiveBPM: String = {
            guard let bpm, bpm > 0 else { return "--" }
            let val = Int((bpm * Double(audio.playbackRate)).rounded())
            return "\(val) BPM"
        }()
        let isDefaultRate = abs(audio.playbackRate - 1.0) < 0.02

        return HStack(spacing: 4) {
            Button {
                let next = max(0.5, (audio.playbackRate - 0.05 * 1.0))
                let snapped = (next * 20).rounded() / 20
                audio.setPlaybackRate(snapped)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(audio.playbackRate <= 0.51 ? secondary.opacity(0.4) : primary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(audio.playbackRate <= 0.51)

            Button {
                audio.setPlaybackRate(1.0)
            } label: {
                HStack(spacing: 4) {
                    Text("\(ratePct)%")
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(isDefaultRate ? primary : accent)
                    Text("·")
                        .foregroundStyle(secondary)
                    Text(effectiveBPM)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to reset tempo to 100%")

            Button {
                let next = min(1.5, audio.playbackRate + 0.05)
                let snapped = (next * 20).rounded() / 20
                audio.setPlaybackRate(snapped)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(audio.playbackRate >= 1.49 ? secondary.opacity(0.4) : primary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(audio.playbackRate >= 1.49)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var capoCell: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let capoLabel = transpose > 0 ? "Capo +\(transpose)" : "Capo \(transpose)"

        return HStack(spacing: 4) {
            Button {
                audio.chordTransposeSemitones = max(-6, transpose - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(transpose <= -6 ? secondary.opacity(0.4) : primary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(transpose <= -6)

            Button {
                audio.chordTransposeSemitones = 0
            } label: {
                Text(capoLabel)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(transpose == 0 ? primary : accent)
            }
            .buttonStyle(.plain)
            .help("Click to reset Capo / Transpose to 0")

            Button {
                audio.chordTransposeSemitones = min(6, transpose + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(transpose >= 6 ? secondary.opacity(0.4) : primary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(transpose >= 6)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var keyCell: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return HStack(spacing: 4) {
            Text("Key:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary)
            Text(displayedKey ?? "--")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
    }

    private var moreMenuCell: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)

        return Menu {
            Menu("Transpose (\(transpose >= 0 ? "+\(transpose)" : "\(transpose)"))") {
                ForEach(-6...6, id: \.self) { step in
                    Button {
                        audio.chordTransposeSemitones = step
                    } label: {
                        HStack {
                            Text(step == 0 ? "0 (Original)" : (step > 0 ? "+\(step)" : "\(step)"))
                            if step == transpose {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Simplify Chords") {
                Button {
                    if !audio.chordSimpleMode {
                        audio.chordSimpleMode = true
                        Task { await appState.analyzeCurrentTrackChords(force: true) }
                    }
                } label: {
                    HStack {
                        Text("Simple (Maj / Min)")
                        if audio.chordSimpleMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    if audio.chordSimpleMode {
                        audio.chordSimpleMode = false
                        Task { await appState.analyzeCurrentTrackChords(force: true) }
                    }
                } label: {
                    HStack {
                        Text("Extended (+7th)")
                        if !audio.chordSimpleMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await appState.analyzeCurrentTrackChords(force: true) }
            } label: {
                Label("Re-analyze Track", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isAnalyzingChords)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                if !compact {
                    Text("More")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .foregroundStyle(primary)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Transpose, Simplify Chords, and Re-analyze Track")
    }
}

// MARK: - Single-Row Live Beat Strip (54x52 Tiles + 2pt Barlines)

private struct LiveBeatStripView: View {
    @Environment(\.colorScheme) private var colorScheme

    let beats: [BeatChordCell]
    let beatsPerBar: Int
    let activeBeatIndex: Int?
    let currentTime: TimeInterval
    let isPlaying: Bool
    let transpose: Int
    let loopRange: ClosedRange<TimeInterval>?
    let autoScroll: Bool
    let compact: Bool
    let isAnalyzing: Bool
    let liveFallbackChord: DetectedChord?
    let onSeekBeat: (BeatChordCell) -> Void

    var body: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)

        return Group {
            if beats.isEmpty {
                HStack(spacing: 10) {
                    if let liveFallbackChord {
                        ChordSymbolText(chord: liveFallbackChord, rootSize: 16, color: accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(0.14)))
                    }
                    Text(isAnalyzing ? "Building beat strip from audio..." : "Beat strip will appear once audio is analyzed.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 62)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 4) {
                            ForEach(Array(beats.enumerated()), id: \.element.id) { index, beat in
                                if index > 0 && beat.beatIndex == 0 {
                                    Rectangle()
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.22))
                                        .frame(width: 2, height: 48)
                                        .padding(.horizontal, 2)
                                }

                                let isCurrent = (activeBeatIndex == index)
                                let isLooped = loopRange.map { $0.overlaps(beat.startTime...beat.endTime) } ?? false
                                let beatProgress: Double = {
                                    guard isCurrent else { return 0 }
                                    let span = max(0.05, beat.endTime - beat.startTime)
                                    return min(1.0, max(0.0, (currentTime - beat.startTime) / span))
                                }()

                                BeatStripTile(
                                    beat: beat,
                                    isCurrent: isCurrent,
                                    isPlaying: isPlaying,
                                    isLooped: isLooped,
                                    progress: beatProgress,
                                    transpose: transpose,
                                    onTap: { onSeekBeat(beat) }
                                )
                                .id(beat.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
                    .onChange(of: activeBeatIndex) { _, newIdx in
                        guard autoScroll, let newIdx, beats.indices.contains(newIdx) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(beats[newIdx].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

private struct BeatStripTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let beat: BeatChordCell
    let isCurrent: Bool
    let isPlaying: Bool
    let isLooped: Bool
    let progress: Double
    let transpose: Int
    let onTap: () -> Void

    private var displayedChord: DetectedChord? {
        beat.chord?.transposed(by: transpose)
    }

    private var showLabel: Bool {
        displayedChord != nil && (beat.isChordChange || isCurrent)
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        let tileFill: Color = {
            if isCurrent {
                return isDark ? SoundChordTheme.darkAccent : Color(red: 0x2F / 255.0, green: 0x31 / 255.0, blue: 0x34 / 255.0)
            }
            return isDark ? SoundChordTheme.darkSurfaceVariant : SoundChordTheme.lightBackground
        }()

        let textColor: Color = {
            if isCurrent {
                return isDark ? Color.black : Color.white
            }
            return SoundChordTheme.primaryText(for: colorScheme)
        }()

        let barFill: Color = isDark ? Color.black.opacity(0.65) : Color.white.opacity(0.85)
        let glowColor: Color = (isCurrent && isPlaying)
            ? (isDark ? SoundChordTheme.darkAccent.opacity(0.48) : Color.black.opacity(0.24))
            : Color.clear

        return Button(action: onTap) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer(minLength: 2)
                    if showLabel, let chord = displayedChord {
                        ChordSymbolText(chord: chord, rootSize: 15, color: textColor)
                            .padding(.horizontal, 3)
                    } else if isCurrent {
                        Circle()
                            .fill(textColor.opacity(0.6))
                            .frame(width: 5, height: 5)
                    } else {
                        Circle()
                            .fill(SoundChordTheme.secondaryText(for: colorScheme).opacity(0.25))
                            .frame(width: 3, height: 3)
                    }
                    Spacer(minLength: 4)
                }
                .frame(width: 54, height: 52)

                if isCurrent {
                    GeometryReader { geo in
                        let w = max(2, geo.size.width * progress)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(barFill.opacity(0.25))
                            Rectangle().fill(barFill).frame(width: w)
                        }
                    }
                    .frame(height: 3)
                } else if isLooped {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                }
            }
            .frame(width: 54, height: 52)
            .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous).fill(tileFill))
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous)
                    .strokeBorder(isCurrent ? Color.clear : (isLooped ? accent.opacity(0.65) : border), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous))
            .shadow(color: glowColor, radius: isCurrent && isPlaying ? 8 : 0)
        }
        .buttonStyle(.plain)
        .help(
            displayedChord.map { "Bar \(beat.barIndex + 1), Beat \(beat.beatIndex + 1): \($0.displayName)" }
                ?? "Bar \(beat.barIndex + 1), Beat \(beat.beatIndex + 1)"
        )
    }
}

// MARK: - Tab 1: Chords Over Lyrics

private struct ChordOverLyricsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let timeline: TrackChordTimeline?
    let beats: [BeatChordCell]
    let lyrics: LyricsDocument?
    let isLoadingLyrics: Bool
    let showTranslatedLyrics: Bool
    let lyricsOffsetSeconds: TimeInterval
    let currentTime: TimeInterval
    let activeSegmentId: UUID?
    let transpose: Int
    let selectedInstrument: ChordsView.ChordInstrument
    let lyricScale: CGFloat
    let autoScroll: Bool
    let compact: Bool
    let onSeek: (TimeInterval) -> Void
    let onRetryLyrics: () -> Void
    let onSwitchToGrid: () -> Void

    private var uniqueDisplayedChords: [DetectedChord] {
        guard let timeline else { return [] }
        var seen = Set<String>()
        var list: [DetectedChord] = []
        for raw in timeline.uniqueChords {
            let shifted = raw.transposed(by: transpose)
            if seen.insert(shifted.displayName).inserted {
                list.append(shifted)
            }
        }
        return list
    }

    var body: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return VStack(spacing: compact ? 8 : 10) {
            if !uniqueDisplayedChords.isEmpty {
                uniqueChordsMiniStrip
            }

            Group {
                if let lyrics, !lyrics.lines.isEmpty, let timeline {
                    alignedLyricsScroll(lyrics: lyrics, timeline: timeline)
                } else if isLoadingLyrics {
                    loadingLyricsPlaceholder
                } else if let timeline, !timeline.segments.isEmpty {
                    instrumentalSectionsFallback(timeline: timeline)
                } else {
                    emptyLyricsAndTimelineFallback
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(cardBg))
            .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
    }

    private var uniqueChordsMiniStrip: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(uniqueDisplayedChords, id: \.displayName) { chord in
                    Button {
                        if let first = timeline?.segments.first(where: { $0.chord.transposed(by: transpose).displayName == chord.displayName }) {
                            onSeek(first.startTime)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            ChordSymbolText(chord: chord, rootSize: 13, color: primary)

                            if selectedInstrument == .guitar {
                                GuitarFretboardView(diagram: chord.guitarDiagram, compact: true)
                                    .frame(width: 78, height: 64)
                            } else {
                                PianoKeyboardView(noteIndices: chord.noteIndices, rootIndex: chord.root, compact: true)
                                    .frame(width: 96, height: 40)
                            }
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(cardBg))
                        .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func alignedLyricsScroll(lyrics: LyricsDocument, timeline: TrackChordTimeline) -> some View {
        let rows = LyricsChordAligner.align(
            lyrics: lyrics,
            timeline: timeline,
            lyricsOffsetSeconds: lyricsOffsetSeconds
        )
        let currentActiveRowId = activeChordLyricRowId(in: rows, at: currentTime)

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: compact ? 12 : 14) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let currentSection = timeline.section(at: row.startTime)
                        let prevSection = index > 0 ? timeline.section(at: rows[index - 1].startTime) : nil
                        if let currentSection, currentSection.id != prevSection?.id {
                            sectionHeadingBanner(section: currentSection)
                        }

                        let isActive = row.id == currentActiveRowId
                        let isPast = row.endTime <= currentTime && !isActive

                        chordLyricRowView(row: row, isActive: isActive, isPast: isPast)
                            .id(row.id)
                    }
                }
                .padding(compact ? 10 : 14)
            }
            .onChange(of: currentActiveRowId) { _, newId in
                guard autoScroll, let newId else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newId, anchor: UnitPoint(x: 0.5, y: 0.28))
                }
            }
        }
    }

    private func sectionHeadingBanner(section: SongSection) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 8) {
            Text(section.label.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(accent)

            Rectangle()
                .fill(border)
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func chordLyricRowView(row: ChordLyricRow, isActive: Bool, isPast: Bool) -> some View {
        switch row {
        case .instrumental(_, let label, let startTime, let endTime, let segments):
            InstrumentalChordRowView(
                label: label,
                startTime: startTime,
                endTime: endTime,
                segments: segments,
                transpose: transpose,
                currentTime: currentTime,
                activeSegmentId: activeSegmentId,
                isActiveRow: isActive,
                compact: compact,
                onSeek: onSeek
            )

        case .lyric(_, let startTime, _, let isBackgroundVocal, let tokens, let translatedText):
            SyncedChordLyricLineRowView(
                startTime: startTime,
                isBackgroundVocal: isBackgroundVocal,
                tokens: tokens,
                translatedText: showTranslatedLyrics ? translatedText : nil,
                transpose: transpose,
                currentTime: currentTime,
                activeSegmentId: activeSegmentId,
                isActiveRow: isActive,
                isPastRow: isPast,
                lyricScale: lyricScale,
                compact: compact,
                onSeek: onSeek
            )
        }
    }

    private func instrumentalSectionsFallback(timeline: TrackChordTimeline) -> some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)

        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("No synced lyrics available for this track. Follow the chord progression by section below.")
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                    Spacer()
                    Button("Retry Lyrics", action: onRetryLyrics)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if timeline.sections.isEmpty {
                    ChordTokenFlowLayout(horizontalSpacing: 6, verticalSpacing: 8) {
                        ForEach(timeline.segments) { seg in
                            Button {
                                onSeek(seg.startTime)
                            } label: {
                                let isSegActive = seg.id == activeSegmentId
                                ChordSymbolText(
                                    chord: seg.chord.transposed(by: transpose),
                                    rootSize: 13,
                                    color: isSegActive ? SoundChordTheme.accentForeground(for: colorScheme) : primary
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSegActive ? accent : SoundChordTheme.elevatedBackground(for: colorScheme))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ForEach(timeline.sections) { section in
                        let sectionSegs = timeline.segments.filter {
                            $0.endTime > section.startTime && $0.startTime < section.endTime
                        }
                        InstrumentalChordRowView(
                            label: section.label,
                            startTime: section.startTime,
                            endTime: section.endTime,
                            segments: sectionSegs,
                            transpose: transpose,
                            currentTime: currentTime,
                            activeSegmentId: activeSegmentId,
                            isActiveRow: currentTime >= section.startTime && currentTime < section.endTime,
                            compact: compact,
                            onSeek: onSeek
                        )
                    }
                }
            }
            .padding(14)
        }
    }

    private var loadingLyricsPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .tint(SoundChordTheme.accentColor(for: colorScheme))
            Text("Fetching synced lyrics...")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLyricsAndTimelineFallback: some View {
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(secondary.opacity(0.75))
            Text("Chords and lyrics will appear here once analysis completes.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                Button(action: onSwitchToGrid) {
                    Text("Open Chords Grid")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentFg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)

                Button("Retry Lyrics", action: onRetryLyrics)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activeChordLyricRowId(in rows: [ChordLyricRow], at time: TimeInterval) -> String? {
        guard !rows.isEmpty else { return nil }
        if let exact = rows.first(where: { time >= $0.startTime - 0.05 && time < $0.endTime }) {
            return exact.id
        }
        var latest: String?
        for row in rows {
            if row.startTime <= time + 0.08 {
                latest = row.id
            } else {
                break
            }
        }
        return latest ?? rows.first?.id
    }
}

// MARK: - Tab 2: Chord Diagrams (Animated Carousel + Summary Grid)

private struct ChordDiagramsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let timeline: TrackChordTimeline?
    let diagramsMode: ChordsView.ChordDiagramsSubMode
    let selectedInstrument: ChordsView.ChordInstrument
    let currentTime: TimeInterval
    let activeSegment: TimedChordSegment?
    let activeChord: DetectedChord?
    let transpose: Int
    let compact: Bool
    let onSeek: (TimeInterval) -> Void

    private var changeSegments: [TimedChordSegment] {
        timeline?.chordChangeSegments ?? []
    }

    private var uniqueChords: [DetectedChord] {
        guard let timeline else { return [] }
        var seen = Set<String>()
        var result: [DetectedChord] = []
        for raw in timeline.uniqueChords {
            let shifted = raw.transposed(by: transpose)
            if seen.insert(shifted.displayName).inserted {
                result.append(shifted)
            }
        }
        return result
    }

    var body: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return Group {
            if diagramsMode == .animated {
                animatedCarouselContent
            } else {
                summaryGridContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(border, lineWidth: 1))
    }

    @ViewBuilder
    private var animatedCarouselContent: some View {
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        if changeSegments.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                if let activeChord {
                    diagramCard(
                        chord: activeChord,
                        subtitle: activeChord.noteNamesList.joined(separator: " · "),
                        isActive: true,
                        progress: 0.5,
                        large: true
                    )
                } else {
                    Text("Waiting for chord diagrams...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondary)
                }
                Spacer()
            }
            .padding(16)
        } else {
            let currentIdx = changeSegments.firstIndex(where: { currentTime >= $0.startTime && currentTime < $0.endTime })
                ?? changeSegments.lastIndex(where: { $0.startTime <= currentTime })
                ?? 0
            let upcomingSlice = Array(changeSegments.dropFirst(currentIdx).prefix(8))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(Array(upcomingSlice.enumerated()), id: \.element.id) { offset, seg in
                            let displayed = seg.chord.transposed(by: transpose)
                            let isCurrent = offset == 0 && currentTime >= seg.startTime && currentTime <= seg.endTime + 0.05
                            let progress: Double = {
                                guard isCurrent else { return 0 }
                                let span = max(0.05, seg.duration)
                                return min(1.0, max(0.0, (currentTime - seg.startTime) / span))
                            }()

                            Button {
                                onSeek(seg.startTime)
                            } label: {
                                diagramCard(
                                    chord: displayed,
                                    subtitle: isCurrent ? "NOW · \(displayed.noteNamesList.joined(separator: " · "))" : Track.formatTime(seg.startTime),
                                    isActive: isCurrent,
                                    progress: progress,
                                    large: offset == 0
                                )
                            }
                            .buttonStyle(.plain)
                            .id(seg.id)
                        }
                    }
                    .padding(compact ? 12 : 20)
                }
                .onChange(of: currentIdx) { _, _ in
                    if let firstId = upcomingSlice.first?.id {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(firstId, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summaryGridContent: some View {
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        if uniqueChords.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No unique chords detected yet.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondary)
                Spacer()
            }
        } else {
            let minCol: CGFloat = selectedInstrument == .piano ? 185 : (compact ? 115 : 148)
            let cols = [GridItem(.adaptive(minimum: minCol, maximum: 230), spacing: 12)]

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(uniqueChords, id: \.displayName) { chord in
                        let isNow = activeChord?.displayName == chord.displayName
                        Button {
                            if let first = timeline?.segments.first(where: { $0.chord.transposed(by: transpose).displayName == chord.displayName }) {
                                onSeek(first.startTime)
                            }
                        } label: {
                            diagramCard(
                                chord: chord,
                                subtitle: chord.noteNamesList.joined(separator: " · "),
                                isActive: isNow,
                                progress: isNow ? 1.0 : 0.0,
                                large: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(compact ? 10 : 16)
            }
        }
    }

    private func diagramCard(
        chord: DetectedChord,
        subtitle: String,
        isActive: Bool,
        progress: Double,
        large: Bool
    ) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let panelBg = SoundChordTheme.panelBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        let cardWidth: CGFloat = {
            if selectedInstrument == .piano {
                return large ? (compact ? 220 : 280) : (compact ? 175 : 210)
            }
            return large ? (compact ? 170 : 210) : (compact ? 120 : 148)
        }()

        return VStack(spacing: 8) {
            HStack {
                ChordSymbolText(chord: chord, rootSize: large ? 22 : 17, color: primary)
                Spacer()
                if isActive {
                    Text("NOW")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(accentFg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                }
            }

            if selectedInstrument == .guitar {
                GuitarFretboardView(diagram: chord.guitarDiagram, compact: !large)
                    .frame(height: large ? (compact ? 132 : 172) : (compact ? 104 : 128))
            } else {
                PianoKeyboardView(noteIndices: chord.noteIndices, rootIndex: chord.root, compact: !large)
                    .frame(height: large ? (compact ? 84 : 112) : (compact ? 64 : 78))
            }

            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(isActive ? accent : secondary)
                .lineLimit(1)

            if large {
                GeometryReader { geo in
                    let w = max(0, geo.size.width * progress)
                    ZStack(alignment: .leading) {
                        Capsule().fill(border)
                        Capsule().fill(accent).frame(width: w)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(large ? 14 : 10)
        .frame(width: cardWidth)
        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(panelBg))
        .overlay(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .strokeBorder(isActive ? accent : border, lineWidth: isActive ? 1.5 : 1)
        )
    }
}

// MARK: - Tab 3: Chords Grid (4 Bars per Row + Section Edge Tabs)

private struct ChordsGridView: View {
    @Environment(\.colorScheme) private var colorScheme

    let timeline: TrackChordTimeline?
    let beats: [BeatChordCell]
    let beatsPerBar: Int
    let activeBeatIndex: Int?
    let currentTime: TimeInterval
    let isPlaying: Bool
    let transpose: Int
    let loopRange: ClosedRange<TimeInterval>?
    let isLoopPickingMode: Bool
    let loopPickAnchorBeat: BeatChordCell?
    let autoScroll: Bool
    let compact: Bool
    let onTapBeat: (BeatChordCell) -> Void
    let onReanalyze: () -> Void

    private struct BarGroup: Identifiable {
        let id: Int
        let barIndex: Int
        let beats: [BeatChordCell]
        var startTime: TimeInterval { beats.first?.startTime ?? 0 }
    }

    private struct BarRow: Identifiable {
        let id: Int
        let bars: [BarGroup]
        let section: SongSection?
        var firstBarNumber: Int { (bars.first?.barIndex ?? 0) + 1 }
    }

    private var barsPerRow: Int {
        compact ? 2 : 4
    }

    private var barRows: [BarRow] {
        guard !beats.isEmpty else { return [] }
        let groupedDict = Dictionary(grouping: beats, by: \.barIndex)
        let sortedKeys = groupedDict.keys.sorted()
        let barGroups: [BarGroup] = sortedKeys.map { key in
            BarGroup(id: key, barIndex: key, beats: groupedDict[key] ?? [])
        }

        var rows: [BarRow] = []
        var idx = 0
        while idx < barGroups.count {
            let end = min(barGroups.count, idx + barsPerRow)
            let slice = Array(barGroups[idx..<end])
            let rowTime = slice.first?.startTime ?? 0
            let section = timeline?.section(at: rowTime)
            rows.append(BarRow(id: idx, bars: slice, section: section))
            idx = end
        }
        return rows
    }

    var body: some View {
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return Group {
            if barRows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("No chord grid generated yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondary)
                    Button(action: onReanalyze) {
                        Text("Analyze Track Chords")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accentFg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            } else {
                let activeBarIndex = activeBeatIndex.flatMap { beats.indices.contains($0) ? beats[$0].barIndex : nil }
                let activeRowId = barRows.first(where: { row in
                    row.bars.contains(where: { $0.barIndex == activeBarIndex })
                })?.id

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(barRows.enumerated()), id: \.element.id) { rowIdx, row in
                                let prevSection = rowIdx > 0 ? barRows[rowIdx - 1].section : nil
                                let isNewSection = row.section != nil && row.section?.id != prevSection?.id

                                GridBarRowView(
                                    row: row,
                                    beatsPerBar: beatsPerBar,
                                    barsPerRow: barsPerRow,
                                    isNewSection: isNewSection,
                                    activeBeatId: activeBeatIndex.flatMap { beats.indices.contains($0) ? beats[$0].id : nil },
                                    currentTime: currentTime,
                                    isPlaying: isPlaying,
                                    transpose: transpose,
                                    loopRange: loopRange,
                                    loopPickAnchorId: loopPickAnchorBeat?.id,
                                    compact: compact,
                                    onTapBeat: onTapBeat
                                )
                                .id(row.id)
                            }
                        }
                        .padding(compact ? 8 : 12)
                    }
                    .onChange(of: activeRowId) { _, newRowId in
                        guard autoScroll, let newRowId else { return }
                        withAnimation(.easeInOut(duration: 0.30)) {
                            proxy.scrollTo(newRowId, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(border, lineWidth: 1))
    }

    private struct GridBarRowView: View {
        @Environment(\.colorScheme) private var colorScheme

        let row: BarRow
        let beatsPerBar: Int
        let barsPerRow: Int
        let isNewSection: Bool
        let activeBeatId: UUID?
        let currentTime: TimeInterval
        let isPlaying: Bool
        let transpose: Int
        let loopRange: ClosedRange<TimeInterval>?
        let loopPickAnchorId: UUID?
        let compact: Bool
        let onTapBeat: (BeatChordCell) -> Void

        private func sectionColor(_ kind: SongSectionKind?) -> Color {
            guard let kind else { return Color.clear }
            switch kind {
            case .intro: return Color(red: 0.30, green: 0.62, blue: 0.96)
            case .verse: return Color(red: 0.18, green: 0.72, blue: 0.56)
            case .preChorus: return Color(red: 0.94, green: 0.64, blue: 0.18)
            case .chorus: return SoundChordTheme.accentColor(for: colorScheme)
            case .bridge: return Color(red: 0.68, green: 0.36, blue: 0.94)
            case .outro: return Color.gray
            }
        }

        var body: some View {
            let secondary = SoundChordTheme.secondaryText(for: colorScheme)
            let accent = SoundChordTheme.accentColor(for: colorScheme)
            let border = SoundChordTheme.hairline(for: colorScheme)
            let isDark = colorScheme == .dark
            let secColor = sectionColor(row.section?.kind)

            return VStack(alignment: .leading, spacing: 4) {
                if isNewSection, let section = row.section {
                    HStack(spacing: 6) {
                        Text(section.label.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(secColor)
                            .tracking(0.7)
                        Rectangle()
                            .fill(secColor.opacity(0.30))
                            .frame(height: 1)
                    }
                    .padding(.leading, 26)
                }

                HStack(alignment: .center, spacing: 6) {
                    // Subtle color-coded left section edge tab + bar number
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(secColor)
                            .frame(width: 4, height: compact ? 36 : 42)

                        Text("\(row.firstBarNumber)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(secondary)
                            .frame(width: 22, alignment: .trailing)
                    }

                    HStack(spacing: 4) {
                        ForEach(0..<barsPerRow, id: \.self) { slot in
                            if slot > 0 {
                                Rectangle()
                                    .fill(isDark ? Color.white.opacity(0.24) : Color.black.opacity(0.22))
                                    .frame(width: 2, height: compact ? 36 : 42)
                            }

                            if slot < row.bars.count {
                                let bar = row.bars[slot]
                                HStack(spacing: 3) {
                                    ForEach(0..<beatsPerBar, id: \.self) { beatSlot in
                                        if beatSlot < bar.beats.count {
                                            let beat = bar.beats[beatSlot]
                                            let isCurrent = beat.id == activeBeatId
                                            let isLooped = loopRange.map { $0.overlaps(beat.startTime...beat.endTime) } ?? false
                                            let isAnchor = beat.id == loopPickAnchorId
                                            let progress: Double = {
                                                guard isCurrent else { return 0 }
                                                let span = max(0.05, beat.endTime - beat.startTime)
                                                return min(1.0, max(0.0, (currentTime - beat.startTime) / span))
                                            }()

                                            GridBeatCellView(
                                                beat: beat,
                                                isCurrent: isCurrent,
                                                isPlaying: isPlaying,
                                                isLooped: isLooped || isAnchor,
                                                progress: progress,
                                                transpose: transpose,
                                                accent: accent,
                                                border: border,
                                                compact: compact,
                                                onTap: { onTapBeat(beat) }
                                            )
                                        } else {
                                            Color.clear
                                                .frame(maxWidth: .infinity)
                                                .frame(height: compact ? 38 : 44)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: compact ? 38 : 44)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct GridBeatCellView: View {
    @Environment(\.colorScheme) private var colorScheme

    let beat: BeatChordCell
    let isCurrent: Bool
    let isPlaying: Bool
    let isLooped: Bool
    let progress: Double
    let transpose: Int
    let accent: Color
    let border: Color
    let compact: Bool
    let onTap: () -> Void

    private var displayedChord: DetectedChord? {
        beat.chord?.transposed(by: transpose)
    }

    private var showLabel: Bool {
        displayedChord != nil && (beat.isChordChange || isCurrent)
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let tileFill: Color = {
            if isCurrent {
                return isDark ? SoundChordTheme.darkAccent : Color(red: 0x2F / 255.0, green: 0x31 / 255.0, blue: 0x34 / 255.0)
            }
            return isDark ? SoundChordTheme.darkSurfaceVariant : SoundChordTheme.lightBackground
        }()
        let textColor: Color = {
            if isCurrent {
                return isDark ? Color.black : Color.white
            }
            return SoundChordTheme.primaryText(for: colorScheme)
        }()
        let glowColor: Color = (isCurrent && isPlaying)
            ? (isDark ? SoundChordTheme.darkAccent.opacity(0.45) : Color.black.opacity(0.22))
            : Color.clear

        return Button(action: onTap) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer(minLength: 1)
                    if showLabel, let chord = displayedChord {
                        ChordSymbolText(chord: chord, rootSize: compact ? 11.5 : 13, color: textColor)
                            .padding(.horizontal, 2)
                    } else if isCurrent {
                        Circle()
                            .fill(textColor.opacity(0.6))
                            .frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 38 : 44)

                if isCurrent {
                    GeometryReader { geo in
                        let w = max(2, geo.size.width * progress)
                        let barColor = isDark ? Color.black.opacity(0.65) : Color.white.opacity(0.85)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(barColor.opacity(0.25))
                            Rectangle().fill(barColor).frame(width: w)
                        }
                    }
                    .frame(height: 2.5)
                } else if isLooped {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 38 : 44)
            .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous).fill(tileFill))
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous)
                    .strokeBorder(isCurrent ? Color.clear : (isLooped ? accent : border), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusBeatCell, style: .continuous))
            .shadow(color: glowColor, radius: isCurrent && isPlaying ? 7 : 0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Synced Lyrics + Chords Flow Layout & Rows

private struct ChordTokenFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                maxRowWidth = max(maxRowWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        maxRowWidth = max(maxRowWidth, max(0, currentX - horizontalSpacing))
        let totalHeight = currentY + rowHeight
        let finalWidth = proposal.width ?? maxRowWidth
        return CGSize(width: max(0, finalWidth), height: max(0, totalHeight))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width > 0 ? bounds.width : .infinity
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && (currentX - bounds.minX) + size.width > maxWidth {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct SyncedChordLyricLineRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let startTime: TimeInterval
    let isBackgroundVocal: Bool
    let tokens: [ChordLyricToken]
    let translatedText: String?
    let transpose: Int
    let currentTime: TimeInterval
    let activeSegmentId: UUID?
    let isActiveRow: Bool
    let isPastRow: Bool
    let lyricScale: CGFloat
    let compact: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var isHovered = false

    private var wordFontSize: CGFloat {
        let base: CGFloat = (compact ? 14.5 : 17.5) * lyricScale
        return isBackgroundVocal ? base * 0.85 : base
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)
        let rowFill: Color = isActiveRow ? accent.opacity(0.11) : (isHovered ? hoverBg : Color.clear)
        let rowStroke: Color = isActiveRow ? accent.opacity(0.35) : Color.clear

        return VStack(alignment: .leading, spacing: 5) {
            ChordTokenFlowLayout(horizontalSpacing: compact ? 5 : 7, verticalSpacing: compact ? 6 : 8) {
                ForEach(tokens) { token in
                    tokenColumn(for: token)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let translated = translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.system(size: (compact ? 11.5 : 13) * lyricScale, weight: .medium))
                    .foregroundStyle(isActiveRow ? primary.opacity(0.85) : secondary.opacity(0.75))
            }
        }
        .padding(.vertical, compact ? 5 : 7)
        .padding(.horizontal, compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(rowFill))
        .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(rowStroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            onSeek(startTime)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func tokenColumn(for token: ChordLyricToken) -> some View {
        let displayedChord = token.chord?.transposed(by: transpose)
        let isChordActive = isTokenChordActive(token)
        let isWordSung = isActiveRow && currentTime >= token.startTime && currentTime <= max(token.startTime + 0.1, token.endTime)
        let cleanedWord = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayWord = cleanedWord.isEmpty ? token.text : cleanedWord
        let pillHeight: CGFloat = 20 * min(1.2, max(0.9, lyricScale))

        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                if let chord = displayedChord {
                    chordBadgeButton(chord: chord, token: token, isChordActive: isChordActive)
                } else {
                    Color.clear.frame(width: 1, height: pillHeight)
                }
            }
            .frame(height: pillHeight, alignment: .leading)

            Text(displayWord)
                .font(.system(size: wordFontSize, weight: isActiveRow ? .bold : .semibold))
                .italic(isBackgroundVocal)
                .foregroundStyle(wordColor(isWordSung: isWordSung))
        }
    }

    private func isTokenChordActive(_ token: ChordLyricToken) -> Bool {
        if let segId = token.chordSegmentId, let activeSegmentId {
            return segId == activeSegmentId
        }
        let chordStart = token.chordStartTime ?? token.startTime
        return isActiveRow && currentTime >= chordStart && currentTime < max(chordStart + 0.25, token.endTime)
    }

    private func chordBadgeButton(chord: DetectedChord, token: ChordLyricToken, isChordActive: Bool) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let elevated = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)
        let seekTarget = token.chordStartTime ?? token.startTime
        let textColor: Color = isChordActive ? accentFg : accent
        let bgColor: Color = isChordActive ? accent : elevated

        return Button {
            onSeek(seekTarget)
        } label: {
            ChordSymbolText(chord: chord, rootSize: (compact ? 11 : 12) * min(1.2, max(0.9, lyricScale)), color: textColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(bgColor))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isChordActive ? Color.clear : border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Seek to \(chord.displayName) at \(Track.formatTime(seekTarget))")
    }

    private func wordColor(isWordSung: Bool) -> Color {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        if isActiveRow {
            return isWordSung ? primary : primary.opacity(0.92)
        }
        if isHovered {
            return primary.opacity(0.84)
        }
        return isPastRow ? secondary.opacity(0.65) : secondary
    }
}

private struct InstrumentalChordRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segments: [TimedChordSegment]
    let transpose: Int
    let currentTime: TimeInterval
    let activeSegmentId: UUID?
    let isActiveRow: Bool
    let compact: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)
        let elevated = SoundChordTheme.elevatedBackground(for: colorScheme)

        let headerColor: Color = isActiveRow ? accent : secondary
        let cardBg: Color = isActiveRow ? accent.opacity(0.10) : elevated.opacity(0.55)
        let cardBorder: Color = isActiveRow ? accent.opacity(0.35) : border

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "guitars.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(headerColor)

                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(headerColor)

                Text("\(Track.formatTime(startTime)) - \(Track.formatTime(endTime))")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(secondary)

                Spacer()
            }

            if !segments.isEmpty {
                ChordTokenFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(segments) { seg in
                        instrumentalSegmentPill(seg: seg)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
    }

    private func instrumentalSegmentPill(seg: TimedChordSegment) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let elevated = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        let displayed = seg.chord.transposed(by: transpose)
        let isSegActive = (seg.id == activeSegmentId)
            || (currentTime >= seg.startTime && currentTime < seg.endTime)
        let fgColor: Color = isSegActive ? accentFg : primary
        let bgColor: Color = isSegActive ? accent : elevated
        let strokeColor: Color = isSegActive ? Color.clear : border

        return Button {
            onSeek(seg.startTime)
        } label: {
            HStack(spacing: 4) {
                ChordSymbolText(chord: displayed, rootSize: compact ? 11.5 : 12.5, color: fgColor)
                Text(Track.formatTime(seg.startTime))
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(fgColor.opacity(0.8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(strokeColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Jump to \(displayed.displayName) at \(Track.formatTime(seg.startTime))")
    }
}

// MARK: - Guitar Fretboard Diagram (Canvas)

private struct GuitarFretboardView: View {
    let diagram: GuitarChordDiagram
    let compact: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let stringNames = ["E", "A", "D", "G", "B", "e"]
    private let fretCount = 4

    var body: some View {
        let isDark = colorScheme == .dark
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return Canvas { context, size in
            let lineColor = isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.26)
            let nutColor = isDark ? Color.white.opacity(0.90) : Color.black.opacity(0.84)
            let labelColor = isDark ? Color.white.opacity(0.72) : Color.black.opacity(0.68)

            let leftMargin: CGFloat = compact ? 18 : 30
            let rightMargin: CGFloat = compact ? 8 : 16
            let topMargin: CGFloat = compact ? 14 : 24
            let bottomMargin: CGFloat = compact ? 12 : 22

            let boardWidth = max(30, size.width - leftMargin - rightMargin)
            let boardHeight = max(28, size.height - topMargin - bottomMargin)
            let stringSpacing = boardWidth / 5.0
            let fretSpacing = boardHeight / CGFloat(fretCount)

            let baseFret = max(1, diagram.baseFret)

            // 1. Horizontal fret lines
            for fret in 0...fretCount {
                let y = topMargin + CGFloat(fret) * fretSpacing
                var path = Path()
                path.move(to: CGPoint(x: leftMargin, y: y))
                path.addLine(to: CGPoint(x: leftMargin + boardWidth, y: y))

                if fret == 0 && baseFret == 1 {
                    context.stroke(
                        path,
                        with: .color(nutColor),
                        style: StrokeStyle(lineWidth: compact ? 2.5 : 4.0, lineCap: .round)
                    )
                } else {
                    context.stroke(path, with: .color(lineColor), lineWidth: 1.0)
                }
            }

            // 2. Vertical strings
            for s in 0..<6 {
                let x = leftMargin + CGFloat(s) * stringSpacing
                var path = Path()
                path.move(to: CGPoint(x: x, y: topMargin))
                path.addLine(to: CGPoint(x: x, y: topMargin + boardHeight))
                let thickness = CGFloat((compact ? 1.4 : 1.9) - Double(s) * 0.14)
                context.stroke(path, with: .color(lineColor), lineWidth: thickness)

                if !compact {
                    let label = Text(stringNames[s])
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(labelColor)
                    context.draw(
                        context.resolve(label),
                        at: CGPoint(x: x, y: topMargin + boardHeight + 12),
                        anchor: .center
                    )
                }
            }

            // 3. Base fret indicator ("3fr")
            if baseFret > 1 {
                let fretLabel = Text("\(baseFret)fr")
                    .font(.system(size: compact ? 8.5 : 11, weight: .bold, design: .rounded))
                    .foregroundColor(labelColor)
                context.draw(
                    context.resolve(fretLabel),
                    at: CGPoint(x: leftMargin - (compact ? 10 : 15), y: topMargin + fretSpacing * 0.5),
                    anchor: .center
                )
            }

            let dotRadius: CGFloat = min(stringSpacing * 0.38, fretSpacing * 0.36, compact ? 5.2 : 9.5)
            let markerY = topMargin - (compact ? 7 : 12)

            // 4. Muted (x) and Open (o) markers
            for s in 0..<min(6, diagram.frets.count) {
                let fret = diagram.frets[s]
                let x = leftMargin + CGFloat(s) * stringSpacing

                if fret < 0 {
                    let crossSize: CGFloat = compact ? 2.4 : 3.8
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - crossSize, y: markerY - crossSize))
                    cross.addLine(to: CGPoint(x: x + crossSize, y: markerY + crossSize))
                    cross.move(to: CGPoint(x: x + crossSize, y: markerY - crossSize))
                    cross.addLine(to: CGPoint(x: x - crossSize, y: markerY + crossSize))
                    context.stroke(
                        cross,
                        with: .color(labelColor),
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                    )
                } else if fret == 0 {
                    let r: CGFloat = compact ? 2.6 : 4.2
                    let circleRect = CGRect(x: x - r, y: markerY - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: circleRect), with: .color(nutColor), lineWidth: 1.3)
                }
            }

            // 5. Barre bar
            var barreStrings = Set<Int>()
            if let barre = diagram.barreFret {
                let relFret = barre - baseFret + 1
                if (1...fretCount).contains(relFret) {
                    let matchingIndices = (0..<min(6, diagram.frets.count)).filter { diagram.frets[$0] == barre }
                    if let first = matchingIndices.first, let last = matchingIndices.last, last > first {
                        let y = topMargin + (CGFloat(relFret) - 0.5) * fretSpacing
                        let xStart = leftMargin + CGFloat(first) * stringSpacing
                        let xEnd = leftMargin + CGFloat(last) * stringSpacing
                        let barRect = CGRect(
                            x: xStart - dotRadius,
                            y: y - dotRadius * 0.85,
                            width: (xEnd - xStart) + dotRadius * 2,
                            height: dotRadius * 1.7
                        )
                        let capsule = Path(roundedRect: barRect, cornerRadius: dotRadius)
                        context.fill(capsule, with: .color(accent))

                        if !compact {
                            let barreFinger = first < diagram.fingers.count && diagram.fingers[first] > 0
                                ? diagram.fingers[first]
                                : 1
                            let fText = Text("\(barreFinger)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(accentFg)
                            context.draw(
                                context.resolve(fText),
                                at: CGPoint(x: (xStart + xEnd) * 0.5, y: y),
                                anchor: .center
                            )
                        }

                        barreStrings = Set(matchingIndices)
                    }
                }
            }

            // 6. Individual finger dots
            for s in 0..<min(6, diagram.frets.count) {
                let fret = diagram.frets[s]
                guard fret >= 1, !barreStrings.contains(s) else { continue }
                let relFret = fret - baseFret + 1
                guard (1...fretCount).contains(relFret) else { continue }

                let x = leftMargin + CGFloat(s) * stringSpacing
                let y = topMargin + (CGFloat(relFret) - 0.5) * fretSpacing
                let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

                context.fill(Path(ellipseIn: dotRect), with: .color(accent))

                if !compact, s < diagram.fingers.count, diagram.fingers[s] > 0 {
                    let fText = Text("\(diagram.fingers[s])")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(accentFg)
                    context.draw(context.resolve(fText), at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
        .accessibilityLabel("Guitar chord fretboard diagram")
    }
}

// MARK: - 2-Octave Piano Keyboard View

private struct PianoKeyboardView: View {
    let noteIndices: [Int]
    let rootIndex: Int
    let compact: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let whitePitchClasses = [0, 2, 4, 5, 7, 9, 11]

    private let blackKeySpecs: [(whiteIndex: Int, pitchClass: Int)] = [
        (0, 1), // C#
        (1, 3), // D#
        (3, 6), // F#
        (4, 8), // G#
        (5, 10) // A#
    ]

    private var activeSet: Set<Int> {
        Set(noteIndices.map { (($0 % 12) + 12) % 12 })
    }

    private var normalizedRoot: Int {
        ((rootIndex % 12) + 12) % 12
    }

    private func noteLabel(for pitchClass: Int) -> String {
        let names = DetectedChord.noteNames
        if pitchClass >= 0 && pitchClass < names.count {
            return names[pitchClass]
        }
        let fallback = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return fallback[((pitchClass % 12) + 12) % 12]
    }

    var body: some View {
        let border = SoundChordTheme.hairline(for: colorScheme)

        return GeometryReader { geo in
            let totalWhiteKeys = 14
            let gap: CGFloat = 1.5
            let whiteWidth = max(6, (geo.size.width - gap * CGFloat(totalWhiteKeys - 1)) / CGFloat(totalWhiteKeys))
            let whiteHeight = geo.size.height
            let blackWidth = whiteWidth * 0.64
            let blackHeight = whiteHeight * 0.60
            let step = whiteWidth + gap

            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    ForEach(0..<totalWhiteKeys, id: \.self) { index in
                        let pitchClass = whitePitchClasses[index % 7]
                        let isRoot = pitchClass == normalizedRoot
                        let isActive = activeSet.contains(pitchClass)

                        whiteKeyView(pitchClass: pitchClass, isActive: isActive, isRoot: isRoot)
                            .frame(width: whiteWidth, height: whiteHeight)
                    }
                }

                ForEach(0..<2, id: \.self) { octave in
                    ForEach(blackKeySpecs, id: \.pitchClass) { spec in
                        let whiteIdx = octave * 7 + spec.whiteIndex
                        let centerX = CGFloat(whiteIdx + 1) * step - gap * 0.5
                        let isRoot = spec.pitchClass == normalizedRoot
                        let isActive = activeSet.contains(spec.pitchClass)

                        blackKeyView(pitchClass: spec.pitchClass, isActive: isActive, isRoot: isRoot)
                            .frame(width: blackWidth, height: blackHeight)
                            .position(x: centerX, y: blackHeight * 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityLabel("Two-octave piano chord keyboard")
    }

    private func whiteKeyView(pitchClass: Int, isActive: Bool, isRoot: Bool) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let baseFill: Color = {
            if isRoot { return accent }
            if isActive { return accent.opacity(0.75) }
            return colorScheme == .dark ? Color.white.opacity(0.92) : Color.white
        }()
        let borderColor: Color = isRoot ? accentFg.opacity(0.45) : Color.black.opacity(0.16)
        let labelSize: CGFloat = compact ? 7 : 9

        return ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 2,
                style: .continuous
            )
            .fill(baseFill)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: 3,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .strokeBorder(borderColor, lineWidth: 0.6)
            )

            if isActive && !compact {
                Text(noteLabel(for: pitchClass))
                    .font(.system(size: labelSize, weight: isRoot ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(accentFg)
                    .padding(.bottom, 4)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isActive)
    }

    private func blackKeyView(pitchClass: Int, isActive: Bool, isRoot: Bool) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let baseFill: Color = {
            if isRoot { return accent }
            if isActive { return accent.opacity(0.80) }
            return Color(red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x1A / 255.0)
        }()
        let borderColor: Color = isRoot ? accentFg.opacity(0.55) : Color.white.opacity(0.16)
        let labelSize: CGFloat = compact ? 6 : 7.5

        return ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 1,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 1,
                style: .continuous
            )
            .fill(baseFill)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 1,
                    bottomLeadingRadius: 3,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 1,
                    style: .continuous
                )
                .strokeBorder(borderColor, lineWidth: 0.6)
            )

            if isRoot && !compact {
                Text(noteLabel(for: pitchClass))
                    .font(.system(size: labelSize, weight: .bold, design: .rounded))
                    .foregroundStyle(accentFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.bottom, 3)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isActive)
    }
}
