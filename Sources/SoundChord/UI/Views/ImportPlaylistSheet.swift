import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ImportPlaylistSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum ImportPhase: Equatable {
        case empty
        case extracting
        case matching(completed: Int, total: Int)
        case error(String, isGated: Bool)
        case ready
    }

    @State private var urlInput: String = ""
    @State private var phase: ImportPhase = .empty
    @State private var preview: ImportedPlaylistPreview?
    @State private var editableTitle: String = ""
    @State private var candidates: [ImportedTrackCandidate] = []
    @State private var activeTask: Task<Void, Never>?
    @State private var rematchingCandidateId: String?
    @State private var manualSearchQuery: String = ""
    @State private var manualSearchResults: [Track] = []
    @State private var isManualSearching: Bool = false

    private let importer = PlaylistImporter()

    public init(preview: ImportedPlaylistPreview? = nil) {
        if let preview {
            _urlInput = State(initialValue: preview.sourceURL)
            _phase = State(initialValue: .ready)
            _preview = State(initialValue: preview)
            _editableTitle = State(initialValue: preview.title)
            _candidates = State(initialValue: preview.candidates)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()
                .overlay(hairlineColor)

            inputSection
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()
                .overlay(hairlineColor)

            stageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(hairlineColor)

            footerSection
        }
        .frame(width: 720, height: 600)
        .background(sheetBackgroundColor)
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
        }
        .onExitCommand {
            cancelAndDismiss()
        }
    }

    // MARK: - Theme Palette (WCAG AA >= 4.5:1 in Light & Dark)

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var sheetBackgroundColor: Color {
        isDark
            ? Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
            : Color.white
    }

    private var cardSurfaceColor: Color {
        isDark
            ? Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0)
            : Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
    }

    private var elevatedSurfaceColor: Color {
        isDark
            ? Color(red: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x24 / 255.0)
            : Color(red: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xEF / 255.0)
    }

    private var primaryTextColor: Color {
        isDark
            ? Color.white
            : Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)
    }

    private var secondaryTextColor: Color {
        isDark
            ? Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB3 / 255.0)
            : Color(red: 0x51 / 255.0, green: 0x51 / 255.0, blue: 0x54 / 255.0)
    }

    private var accentColor: Color {
        isDark
            ? Color(red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0)
            : Color(red: 0xD6 / 255.0, green: 0x00 / 255.0, blue: 0x17 / 255.0)
    }

    private var accentTextColor: Color {
        isDark
            ? Color(red: 0x1E / 255.0, green: 0xD7 / 255.0, blue: 0x60 / 255.0)
            : Color(red: 0xD6 / 255.0, green: 0x00 / 255.0, blue: 0x17 / 255.0)
    }

    private var primaryButtonForegroundColor: Color {
        isDark ? Color.black : Color.white
    }

    private var matchedBadgeTextColor: Color {
        isDark
            ? Color(red: 0x1E / 255.0, green: 0xD7 / 255.0, blue: 0x60 / 255.0)
            : Color(red: 0x14 / 255.0, green: 0x6C / 255.0, blue: 0x33 / 255.0)
    }

    private var matchedBadgeFillColor: Color {
        isDark
            ? Color(red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0).opacity(0.18)
            : Color(red: 0x16 / 255.0, green: 0xA3 / 255.0, blue: 0x4A / 255.0).opacity(0.14)
    }

    private var hairlineColor: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }

    // MARK: - Computed Properties

    private var detectedPlatform: ImportPlatform? {
        PlaylistImporter.detectPlatform(from: urlInput)
    }

    private var isBusy: Bool {
        switch phase {
        case .extracting, .matching:
            return true
        case .empty, .error, .ready:
            return false
        }
    }

    private var matchedCandidatesCount: Int {
        candidates.filter { $0.matchedTrack != nil }.count
    }

    private var selectedCandidatesCount: Int {
        candidates.filter { $0.isSelected && $0.matchedTrack != nil }.count
    }

    private var areAllMatchedSelected: Bool {
        let matched = candidates.filter { $0.matchedTrack != nil }
        return !matched.isEmpty && matched.allSatisfy(\.isSelected)
    }

    private var canSaveToLibrary: Bool {
        !isBusy &&
        preview != nil &&
        selectedCandidatesCount > 0 &&
        !editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Header & Input Sections

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accentTextColor)
                .frame(width: 36, height: 36)
                .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hairlineColor, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Import Playlist")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(primaryTextColor)

                Text("YouTube, Spotify, Apple Music, Deezer, SoundCloud, Tidal, M3U/CSV")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
            }

            Spacer()

            Button {
                cancelAndDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .background(cardSurfaceColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: detectedPlatform?.iconName ?? "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(detectedPlatform != nil ? accentTextColor : secondaryTextColor)

                    TextField("Paste a public playlist or album URL...", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(primaryTextColor)
                        .onSubmit {
                            startURLImport()
                        }

                    if !urlInput.isEmpty && !isBusy {
                        Button {
                            urlInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(secondaryTextColor)
                        }
                        .buttonStyle(.plain)
                    }

                    if let platform = detectedPlatform {
                        platformBadge(platform)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hairlineColor, lineWidth: 1)
                )

                Button {
                    startURLImport()
                } label: {
                    Text("Fetch Playlist")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(primaryButtonForegroundColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                .opacity(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy ? 0.5 : 1.0)

                Button {
                    pickLocalPlaylistFile()
                } label: {
                    Label("Import M3U / CSV", systemImage: "doc.badge.plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(primaryTextColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(hairlineColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    private func platformBadge(_ platform: ImportPlatform) -> some View {
        HStack(spacing: 4) {
            Image(systemName: platform.iconName)
                .font(.system(size: 10.5, weight: .semibold))
            Text(platform.displayName)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(accentTextColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(accentColor.opacity(0.14), in: Capsule())
    }

    // MARK: - Stage States (Empty, Loading, Error, Ready)

    @ViewBuilder
    private var stageBody: some View {
        switch phase {
        case .empty:
            emptyStateView
        case .extracting:
            loadingStateView(
                title: "Extracting playlist...",
                subtitle: "Reading playlist metadata and track list",
                progress: nil
            )
        case .matching(let completed, let total):
            loadingStateView(
                title: "Matching tracks \(completed) / \(total)",
                subtitle: "Resolving tracks in YouTube Music catalog",
                progress: total > 0 ? Double(completed) / Double(total) : 0
            )
        case .error(let message, let isGated):
            errorStateView(message: message, isGated: isGated)
        case .ready:
            readyPreviewView
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(secondaryTextColor)

            VStack(spacing: 6) {
                Text("Bring your playlists into SoundChord")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Text("Paste a public playlist link above, or import an exported .m3u, .m3u8, or .csv file.")
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 8) {
                ForEach(ImportPlatform.allCases) { platform in
                    HStack(spacing: 5) {
                        Image(systemName: platform.iconName)
                            .font(.system(size: 10.5))
                        Text(platform.displayName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hairlineColor, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(24)
    }

    private func loadingStateView(
        title: String,
        subtitle: String,
        progress: Double?
    ) -> some View {
        VStack(spacing: 14) {
            Spacer()

            if let progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .frame(width: 280)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(primaryTextColor)

                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondaryTextColor)
            }

            Button("Cancel Fetch") {
                activeTask?.cancel()
                activeTask = nil
                phase = preview != nil ? .ready : .empty
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondaryTextColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hairlineColor, lineWidth: 1)
            )

            Spacer()
        }
        .padding(24)
    }

    private func errorStateView(message: String, isGated: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(accentTextColor)

                Text("Unable to Import Playlist")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                HStack(spacing: 10) {
                    Button {
                        startURLImport()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(primaryButtonForegroundColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isGated {
                        Button {
                            pickLocalPlaylistFile()
                        } label: {
                            Label("Import M3U / CSV", systemImage: "doc.badge.plus")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(primaryTextColor)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(hairlineColor, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hairlineColor, lineWidth: 1)
            )

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Ready Preview View

    private var readyPreviewView: some View {
        VStack(spacing: 0) {
            if let preview {
                previewMetadataBar(preview: preview)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }

            if let warning = preview?.warningNote, !warning.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accentTextColor)
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(primaryTextColor)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hairlineColor, lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            selectionToolbar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            Divider()
                .overlay(hairlineColor)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        candidateRow(index: index, candidate: candidate)
                        if index < candidates.count - 1 {
                            Divider()
                                .overlay(hairlineColor)
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private func previewMetadataBar(preview: ImportedPlaylistPreview) -> some View {
        HStack(spacing: 14) {
            ArtworkImage(
                url: preview.artworkURL ?? candidates.compactMap { $0.matchedTrack?.artworkURL }.first,
                size: 60,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    platformBadge(preview.platform)

                    if let author = preview.author, !author.isEmpty {
                        Text("by \(author)")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }

                TextField("Playlist Name", text: $editableTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(sheetBackgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hairlineColor, lineWidth: 1)
                    )
            }
        }
        .padding(12)
        .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hairlineColor, lineWidth: 1)
        )
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Button {
                toggleSelectAllMatched()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: areAllMatchedSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(areAllMatchedSelected ? accentTextColor : secondaryTextColor)
                    Text(areAllMatchedSelected ? "Deselect All" : "Select All Matched")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(primaryTextColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(matchedCandidatesCount == 0)

            Spacer()

            Text("\(matchedCandidatesCount) of \(candidates.count) matched")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(secondaryTextColor)
        }
    }

    private func candidateRow(index: Int, candidate: ImportedTrackCandidate) -> some View {
        let isMatched = candidate.matchedTrack != nil
        let isShowingSearchPopover = rematchingCandidateId == candidate.id

        return HStack(spacing: 10) {
            Button {
                toggleSelection(at: index)
            } label: {
                Image(systemName: candidate.isSelected && isMatched ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        isMatched
                            ? (candidate.isSelected ? accentTextColor : secondaryTextColor)
                            : secondaryTextColor.opacity(0.4)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isMatched)

            Text("\(index + 1)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(secondaryTextColor)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.sourceTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(candidate.sourceArtist.isEmpty ? "Unknown Artist" : candidate.sourceArtist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)

                    if let album = candidate.sourceAlbum, !album.isEmpty {
                        Text("·")
                            .font(.system(size: 11.5))
                            .foregroundStyle(secondaryTextColor)
                        Text(album)
                            .font(.system(size: 11.5))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }

                if let matched = candidate.matchedTrack,
                   matched.title.caseInsensitiveCompare(candidate.sourceTitle) != .orderedSame {
                    Text("Matched: \(matched.title) - \(matched.artist)")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if candidate.sourceDuration > 0 {
                Text(Track.formatTime(candidate.sourceDuration))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }

            if isMatched {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("Matched")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(matchedBadgeTextColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(matchedBadgeFillColor, in: Capsule())
            } else {
                Text("No match found")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(elevatedSurfaceColor, in: Capsule())
            }

            Button {
                openManualSearch(for: candidate)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 24, height: 24)
                    .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Search manually for a better match")
            .popover(
                isPresented: Binding(
                    get: { isShowingSearchPopover },
                    set: { shown in
                        if !shown && rematchingCandidateId == candidate.id {
                            rematchingCandidateId = nil
                        }
                    }
                ),
                arrowEdge: .trailing
            ) {
                manualSearchPopover(forIndex: index, candidate: candidate)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func manualSearchPopover(forIndex index: Int, candidate: ImportedTrackCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find Match")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(primaryTextColor)

            HStack(spacing: 6) {
                TextField("Search YouTube Music...", text: $manualSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        runManualSearch()
                    }

                Button("Search") {
                    runManualSearch()
                }
                .disabled(isManualSearching || manualSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if isManualSearching {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if manualSearchResults.isEmpty {
                Text("No results yet. Adjust keywords and press Return.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(manualSearchResults.prefix(8)) { track in
                            Button {
                                applyManualMatch(track, at: index)
                            } label: {
                                HStack(spacing: 8) {
                                    ArtworkImage(url: track.artworkURL, size: 32, cornerRadius: 4)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(primaryTextColor)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 11))
                                            .foregroundStyle(secondaryTextColor)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if track.duration > 0 {
                                        Text(track.formattedDuration)
                                            .font(.system(size: 11))
                                            .monospacedDigit()
                                            .foregroundStyle(secondaryTextColor)
                                    }
                                }
                                .padding(6)
                                .background(cardSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(sheetBackgroundColor)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 12) {
            if case .ready = phase {
                Text("\(selectedCandidatesCount) selected")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }

            Spacer()

            Button("Cancel") {
                cancelAndDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                saveSelectedToLibrary()
            } label: {
                let count = selectedCandidatesCount
                let unit = count == 1 ? "track" : "tracks"
                Text("Save to Library (\(count) \(unit))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(primaryButtonForegroundColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSaveToLibrary)
            .opacity(canSaveToLibrary ? 1.0 : 0.45)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func cancelAndDismiss() {
        activeTask?.cancel()
        activeTask = nil
        dismiss()
    }

    private func startURLImport() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeTask?.cancel()
        phase = .extracting
        preview = nil
        candidates = []

        let innerTube = appState.innerTube
        activeTask = Task {
            do {
                let extracted = try await importer.extractPlaylist(from: trimmed, innerTube: innerTube)
                try Task.checkCancellation()
                await runMatchingPipeline(for: extracted, innerTube: innerTube)
            } catch is CancellationError {
                return
            } catch let importErr as PlaylistImportError {
                let gated: Bool
                if case .gatedPlatform = importErr {
                    gated = true
                } else {
                    gated = false
                }
                await MainActor.run {
                    self.phase = .error(importErr.localizedDescription, isGated: gated)
                }
            } catch {
                await MainActor.run {
                    self.phase = .error(error.localizedDescription, isGated: false)
                }
            }
        }
    }

    private func pickLocalPlaylistFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Playlist File (M3U / CSV)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        var allowedTypes: [UTType] = [.commaSeparatedText]
        if let m3uType = UTType(filenameExtension: "m3u") {
            allowedTypes.append(m3uType)
        }
        if let m3u8Type = UTType(filenameExtension: "m3u8") {
            allowedTypes.append(m3u8Type)
        }
        if let csvType = UTType(filenameExtension: "csv") {
            allowedTypes.append(csvType)
        }
        panel.allowedContentTypes = allowedTypes

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        activeTask?.cancel()
        phase = .extracting
        preview = nil
        candidates = []

        let innerTube = appState.innerTube
        activeTask = Task {
            do {
                let extracted = try await importer.extractFromLocalFile(url: fileURL)
                try Task.checkCancellation()
                await runMatchingPipeline(for: extracted, innerTube: innerTube)
            } catch is CancellationError {
                return
            } catch let importErr as PlaylistImportError {
                await MainActor.run {
                    self.phase = .error(importErr.localizedDescription, isGated: false)
                }
            } catch {
                await MainActor.run {
                    self.phase = .error(error.localizedDescription, isGated: false)
                }
            }
        }
    }

    @MainActor
    private func runMatchingPipeline(
        for extracted: ImportedPlaylistPreview,
        innerTube: InnerTubeClient
    ) async {
        self.preview = extracted
        self.editableTitle = extracted.title
        self.candidates = extracted.candidates

        let needsMatching = extracted.candidates.contains { $0.status != .matched || $0.matchedTrack == nil }
        if !needsMatching {
            self.phase = .ready
            return
        }

        let total = extracted.candidates.count
        let alreadyMatched = extracted.candidates.filter { $0.status == .matched && $0.matchedTrack != nil }.count
        self.phase = .matching(completed: alreadyMatched, total: total)

        let matchedPreview = await importer.matchCandidates(extracted, innerTube: innerTube) { completed, totalCount in
            Task { @MainActor in
                if case .matching = self.phase {
                    self.phase = .matching(completed: completed, total: totalCount)
                }
            }
        }

        guard !Task.isCancelled else { return }
        self.preview = matchedPreview
        self.candidates = matchedPreview.candidates
        if self.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.editableTitle = matchedPreview.title
        }
        self.phase = .ready
    }

    private func toggleSelection(at index: Int) {
        guard candidates.indices.contains(index), candidates[index].matchedTrack != nil else { return }
        candidates[index].isSelected.toggle()
    }

    private func toggleSelectAllMatched() {
        let shouldSelect = !areAllMatchedSelected
        for idx in candidates.indices where candidates[idx].matchedTrack != nil {
            candidates[idx].isSelected = shouldSelect
        }
    }

    private func openManualSearch(for candidate: ImportedTrackCandidate) {
        rematchingCandidateId = candidate.id
        manualSearchQuery = candidate.sourceArtist.isEmpty
            ? candidate.sourceTitle
            : "\(candidate.sourceTitle) \(candidate.sourceArtist)"
        manualSearchResults = []
        runManualSearch()
    }

    private func runManualSearch() {
        let query = manualSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isManualSearching = true
        let innerTube = appState.innerTube
        Task {
            let hits = await importer.searchMatches(for: query, innerTube: innerTube)
            await MainActor.run {
                self.manualSearchResults = hits
                self.isManualSearching = false
            }
        }
    }

    private func applyManualMatch(_ track: Track, at index: Int) {
        guard candidates.indices.contains(index) else { return }
        candidates[index].matchedTrack = track
        candidates[index].matchScore = PlaylistImporter.scoreMatch(candidate: candidates[index], track: track)
        candidates[index].status = .matched
        candidates[index].isSelected = true
        rematchingCandidateId = nil
    }

    private func saveSelectedToLibrary() {
        guard let preview else { return }
        let cleanedTitle = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else { return }

        let tracksToSave = candidates.compactMap { candidate -> Track? in
            guard candidate.isSelected else { return nil }
            return candidate.matchedTrack
        }
        guard !tracksToSave.isEmpty else { return }

        let description = "Imported from \(preview.platform.displayName)"
        let created = appState.libraryStore.createPlaylist(title: cleanedTitle, description: description)
        for track in tracksToSave {
            appState.libraryStore.addToPlaylist(playlistId: created.id, track: track)
        }

        let unit = tracksToSave.count == 1 ? "track" : "tracks"
        appState.showToast("Imported \"\(created.title)\" (\(tracksToSave.count) \(unit))")
        dismiss()
        appState.selectSidebar(.playlist(created.id))
    }
}
