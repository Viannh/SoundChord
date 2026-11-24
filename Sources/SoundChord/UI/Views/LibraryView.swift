import AppKit
import SwiftUI

// MARK: - LibraryView

public struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private enum LibraryTab: String, CaseIterable, Identifiable {
        case liked = "Liked Songs"
        case playlists = "Playlists"
        case history = "Recent History"

        var id: String { rawValue }
    }

    @State private var selectedTab: LibraryTab = .liked
    @State private var filterText: String = ""
    @State private var showCreatePlaylist = false
    @State private var newPlaylistTitle = ""
    @State private var newPlaylistDescription = ""

    private var filteredLiked: [Track] {
        let tracks = appState.libraryStore.likedTracks
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || ($0.album?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredPlaylists: [Playlist] {
        let lists = appState.libraryStore.playlists
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return lists }
        return lists.filter { $0.title.lowercased().contains(q) }
    }

    private var filteredHistory: [ListeningEvent] {
        let events = appState.libraryStore.history
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return events }
        return events.filter {
            $0.track.title.lowercased().contains(q) || $0.track.artist.lowercased().contains(q)
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR COLLECTION")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .tracking(0.8)
                        Text("Library")
                            .font(.system(size: 34, weight: .bold))
                    }

                    Spacer()

                    if selectedTab == .playlists {
                        HStack(spacing: 10) {
                            Button {
                                appState.showImportPlaylistSheet = true
                            } label: {
                                Label("Import Playlist", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button {
                                newPlaylistTitle = ""
                                newPlaylistDescription = ""
                                showCreatePlaylist = true
                            } label: {
                                Label("New Playlist", systemImage: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        playShuffleControls
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                // Segmented Tabs + Inline Filter
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        ForEach(LibraryTab.allCases) { tab in
                            let selected = selectedTab == tab
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    selectedTab = tab
                                }
                            } label: {
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected ? SoundChordTheme.accentForeground(for: colorScheme) : SoundChordTheme.primaryText(for: colorScheme))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? SoundChordTheme.accentColor(for: colorScheme) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        TextField("Filter...", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 150)
                        if !filterText.isEmpty {
                            Button {
                                filterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                }
                .padding(.horizontal, 36)

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                // Tab Content
                switch selectedTab {
                case .liked:
                    likedSongsContent
                case .playlists:
                    playlistsContent
                case .history:
                    historyContent
                }
            }
            .padding(.bottom, 110)
        }
        .sheet(isPresented: $showCreatePlaylist) {
            createPlaylistModal
        }
    }

    @ViewBuilder
    private var playShuffleControls: some View {
        let tracks: [Track] = selectedTab == .liked
            ? filteredLiked
            : filteredHistory.map(\.track)

        if !tracks.isEmpty {
            HStack(spacing: 10) {
                Button {
                    appState.play(track: tracks[0], queue: tracks)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                }
                .buttonStyle(.plain)

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    appState.play(track: shuffled[0], queue: shuffled)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                        .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var likedSongsContent: some View {
        if filteredLiked.isEmpty {
            BCEmptyStateView(
                icon: "heart",
                title: appState.libraryStore.likedTracks.isEmpty ? "No Liked Songs Yet" : "No Matching Songs",
                message: appState.libraryStore.likedTracks.isEmpty
                    ? "Tap the heart icon on any song to save it to your Liked Songs collection."
                    : "Try clearing your search filter.",
                buttonTitle: appState.libraryStore.likedTracks.isEmpty ? "Explore Music" : nil
            ) {
                appState.selectSidebar(.explore)
            }
            .padding(.horizontal, 36)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(Array(filteredLiked.enumerated()), id: \.element.id) { idx, track in
                    BCStandardTrackRow(
                        track: track,
                        index: idx + 1,
                        showArtwork: true,
                        showAlbumColumn: true,
                        queueContext: filteredLiked
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var playlistsContent: some View {
        if filteredPlaylists.isEmpty {
            BCEmptyStateView(
                icon: "music.note.list",
                title: "No Playlists Yet",
                message: "Create custom playlists to organize your favorite tracks for every mood.",
                buttonTitle: "Create Playlist"
            ) {
                newPlaylistTitle = ""
                newPlaylistDescription = ""
                showCreatePlaylist = true
            }
            .padding(.horizontal, 36)
        } else {
            let columns = [GridItem(.adaptive(minimum: 184, maximum: 210), spacing: 20)]
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(filteredPlaylists) { playlist in
                    BCSquareCard(item: .playlist(playlist), size: 184)
                }
            }
            .padding(.horizontal, 36)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if filteredHistory.isEmpty {
            BCEmptyStateView(
                icon: "clock",
                title: "No Listening History",
                message: "Songs you listen to will appear here so you can jump right back in."
            )
            .padding(.horizontal, 36)
        } else {
            let historyTracks = filteredHistory.map(\.track)
            LazyVStack(spacing: 2) {
                ForEach(filteredHistory) { event in
                    BCStandardTrackRow(
                        track: event.track,
                        showArtwork: true,
                        showAlbumColumn: true,
                        queueContext: historyTracks,
                        trailingBadge: relativeTime(event.playedAt)
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var createPlaylistModal: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist")
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. Late Night Drives", text: $newPlaylistTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description (Optional)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("What's the vibe?", text: $newPlaylistDescription)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showCreatePlaylist = false
                }
                Button("Create") {
                    let trimmed = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let desc = newPlaylistDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = appState.libraryStore.createPlaylist(
                        title: trimmed,
                        description: desc.isEmpty ? nil : desc
                    )
                    appState.showToast("Created playlist \"\(created.title)\"")
                    showCreatePlaylist = false
                    appState.openDestination(.playlist(created))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 380)
    }

    @MainActor
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - DownloadsView

public struct DownloadsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var cachedStorageBytes: Int64 = 0

    public init() {}

    private var activeTasks: [DownloadTaskState] {
        appState.libraryStore.activeDownloads.values
            .filter { $0.status == .queued || $0.status == .downloading || $0.status == .failed }
            .sorted { $0.track.title < $1.track.title }
    }

    private var completedTracks: [Track] {
        appState.libraryStore.downloads
    }

    private var completedTrackIdsKey: [String] {
        completedTracks.map(\.id)
    }

    private var formattedStorage: String {
        ByteCountFormatter.string(fromByteCount: cachedStorageBytes, countStyle: .file)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OFFLINE AUDIO")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .tracking(0.8)
                        Text("Downloads")
                            .font(.system(size: 34, weight: .bold))
                    }

                    Spacer()

                    if !completedTracks.isEmpty {
                        HStack(spacing: 10) {
                            Button {
                                appState.play(track: completedTracks[0], queue: completedTracks)
                            } label: {
                                Label("Play Offline", systemImage: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                            }
                            .buttonStyle(.plain)

                            Button {
                                var shuffled = completedTracks
                                shuffled.shuffle()
                                appState.play(track: shuffled[0], queue: shuffled)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                // Storage Summary Bar
                HStack(spacing: 16) {
                    Label("\(completedTracks.count) \(completedTracks.count == 1 ? "track" : "tracks") offline", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Divider().frame(height: 14)
                    Label("\(formattedStorage) used", systemImage: "internaldrive")
                        .font(.system(size: 13))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    Spacer()
                    Text("Quality: \(appState.libraryStore.settings.downloadQuality.displayName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
                .padding(.horizontal, 36)

                // Active Downloads
                if !activeTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Active Downloads")
                            .font(.system(size: 18, weight: .bold))
                            .padding(.horizontal, 36)

                        LazyVStack(spacing: 8) {
                            ForEach(activeTasks) { task in
                                HStack(spacing: 12) {
                                    ArtworkImage(url: task.track.artworkURL, size: 42, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.track.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text(task.track.artist)
                                            .font(.system(size: 12))
                                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                            .lineLimit(1)
                                        if task.status == .failed {
                                            Text(task.error ?? "Download failed")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.red)
                                        } else {
                                            ProgressView(value: min(1.0, max(0.0, task.progress)))
                                                .tint(SoundChordTheme.accentColor(for: colorScheme))
                                        }
                                    }

                                    Spacer()

                                    if task.status == .failed {
                                        Button("Retry") {
                                            appState.download(task.track)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    } else {
                                        Text("\(Int((task.progress * 100).rounded()))%")
                                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                    }
                                }
                                .padding(12)
                                .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
                            }
                        }
                        .padding(.horizontal, 36)
                    }
                }

                // Completed Offline Tracks
                if completedTracks.isEmpty && activeTasks.isEmpty {
                    BCEmptyStateView(
                        icon: "arrow.down.circle",
                        title: "No Downloaded Tracks",
                        message: "Download songs or albums for seamless offline listening on macOS. Right-click any track and select Download."
                    )
                    .padding(.horizontal, 36)
                } else if !completedTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloaded Tracks")
                            .font(.system(size: 18, weight: .bold))
                            .padding(.horizontal, 36)

                        LazyVStack(spacing: 2) {
                            ForEach(Array(completedTracks.enumerated()), id: \.element.id) { idx, track in
                                HStack(spacing: 4) {
                                    BCStandardTrackRow(
                                        track: track,
                                        index: idx + 1,
                                        showArtwork: true,
                                        showAlbumColumn: true,
                                        queueContext: completedTracks,
                                        trailingBadge: track.qualityLabel ?? track.audioCodec?.uppercased()
                                    )

                                    Button {
                                        appState.deleteDownload(track)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete Download")
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: completedTrackIdsKey) {
            let urls: [URL] = completedTracks.compactMap { track in
                track.localFileURL ?? appState.libraryStore.localFileURL(for: track.id)
            }
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                let fm = FileManager.default
                var sum: Int64 = 0
                for url in urls {
                    if let attrs = try? fm.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int64 {
                        sum += size
                    }
                }
                return sum
            }.value
            cachedStorageBytes = total
        }
    }
}

// MARK: - LocalMusicView

public struct LocalMusicView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    @State private var isScanning = false

    private var folders: [String] {
        appState.libraryStore.settings.localMusicFolders
    }

    private var localTracks: [Track] {
        appState.libraryStore.localTracks
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ON THIS MAC")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .tracking(0.8)
                        Text("Local Music")
                            .font(.system(size: 34, weight: .bold))
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button {
                            pickLocalFolder()
                        } label: {
                            Label("Add Folder...", systemImage: "folder.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            rescanAllFolders()
                        } label: {
                            HStack(spacing: 6) {
                                if isScanning {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text("Rescan")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                            .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanning || folders.isEmpty)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                // Watched Folders Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Music Folders")
                        .font(.system(size: 15, weight: .bold))

                    if folders.isEmpty {
                        Text("No folders added yet. Supported formats: FLAC, ALAC, M4A, MP3, WAV, AIFF.")
                            .font(.system(size: 13))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(folders, id: \.self) { path in
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                                    Text(path)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                                    } label: {
                                        Image(systemName: "arrow.up.forward.square")
                                            .font(.system(size: 13))
                                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reveal in Finder")

                                    Button {
                                        appState.libraryStore.removeLocalFolder(path)
                                        appState.showToast("Removed folder")
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove Folder")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                )
                            }
                        }
                    }
                }
                .padding(16)
                .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
                .padding(.horizontal, 36)

                // Tracks List
                if localTracks.isEmpty {
                    BCEmptyStateView(
                        icon: "opticaldisc",
                        title: "No Local Tracks Found",
                        message: "Add a folder containing FLAC, ALAC, M4A, MP3, WAV, or AIFF files to play your lossless local collection with SoundChord's 7-band EQ.",
                        buttonTitle: "Choose Music Folder..."
                    ) {
                        pickLocalFolder()
                    }
                    .padding(.horizontal, 36)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tracks (\(localTracks.count))")
                                .font(.system(size: 18, weight: .bold))
                            Spacer()
                            Button {
                                appState.play(track: localTracks[0], queue: localTracks)
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 36)

                        LazyVStack(spacing: 2) {
                            ForEach(Array(localTracks.enumerated()), id: \.element.id) { idx, track in
                                BCStandardTrackRow(
                                    track: track,
                                    index: idx + 1,
                                    showArtwork: true,
                                    showAlbumColumn: true,
                                    queueContext: localTracks,
                                    trailingBadge: formatBadge(for: track)
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.bottom, 110)
        }
    }

    private func formatBadge(for track: Track) -> String? {
        var parts: [String] = []
        if let codec = track.audioCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        } else if let ext = track.localFileURL?.pathExtension, !ext.isEmpty {
            parts.append(ext.uppercased())
        }
        if let bitDepth = track.bitDepth, bitDepth > 0 {
            parts.append("\(bitDepth)-bit")
        }
        if let kbps = track.bitrateKbps, kbps > 0 {
            parts.append("\(kbps)k")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Local Music Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            isScanning = true
            Task {
                defer { isScanning = false }
                await appState.libraryStore.scanLocalFolder(url)
                appState.showToast("Scanned \(url.lastPathComponent)")
            }
        }
    }

    private func rescanAllFolders() {
        isScanning = true
        let currentFolders = folders
        Task {
            defer { isScanning = false }
            for path in currentFolders {
                await appState.libraryStore.scanLocalFolder(URL(fileURLWithPath: path))
            }
            appState.showToast("Finished rescanning local music")
        }
    }
}

// MARK: - ReplayView

public struct ReplayView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var cachedSummary: ReplaySummary?

    public init() {}

    private struct HistoryCacheKey: Equatable {
        let count: Int
        let firstEventId: UUID?
        let lastEventId: UUID?
    }

    private var historyCacheKey: HistoryCacheKey {
        let history = appState.libraryStore.history
        return HistoryCacheKey(
            count: history.count,
            firstEventId: history.first?.id,
            lastEventId: history.last?.id
        )
    }

    public var body: some View {
        let summary = cachedSummary ?? ReplaySummary()
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("LISTENING INSIGHTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .tracking(0.8)
                    Text("SoundChord Replay")
                        .font(.system(size: 34, weight: .bold))
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                if summary.totalPlays == 0 {
                    BCEmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: "Your Replay Starts Here",
                        message: "Listen to songs in SoundChord to unlock your personalized listening time, top tracks leaderboard, favorite artists, and daily streaks.",
                        buttonTitle: "Start Listening"
                    ) {
                        appState.selectSidebar(.home)
                    }
                    .padding(.horizontal, 36)
                } else {
                    // Hero Stat Cards Grid
                    let statCols = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]
                    LazyVGrid(columns: statCols, spacing: 16) {
                        ReplayStatCard(
                            title: "Total Listening Time",
                            value: formatListeningMinutes(summary.totalMinutes),
                            subtitle: "\(summary.longestStreakDays)-day longest streak",
                            icon: "clock.fill",
                            tint: accent
                        )

                        ReplayStatCard(
                            title: "Tracks Played",
                            value: "\(summary.totalPlays)",
                            subtitle: "\(summary.uniqueTracksCount) unique songs",
                            icon: "music.note",
                            tint: Color(red: 0.25, green: 0.62, blue: 0.98)
                        )

                        ReplayStatCard(
                            title: "Top Artist",
                            value: summary.topArtists.first?.name ?? "--",
                            subtitle: summary.topArtists.first.map { "\($0.playCount) plays" } ?? "\(summary.uniqueArtistsCount) artists",
                            icon: "star.fill",
                            tint: Color(red: 0.72, green: 0.36, blue: 0.96)
                        )

                        ReplayStatCard(
                            title: "Peak Listening Hour",
                            value: summary.peakListeningHour.map(formatHour) ?? "--",
                            subtitle: "\(summary.uniqueArtistsCount) unique artists explored",
                            icon: "sparkles",
                            tint: Color(red: 0.16, green: 0.78, blue: 0.56)
                        )
                    }
                    .padding(.horizontal, 36)

                    // Top Songs Leaderboard
                    if !summary.topTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Top Songs")
                                    .font(.system(size: 18, weight: .bold))
                                Spacer()
                                Button {
                                    let tracks = summary.topTracks.map(\.track)
                                    appState.play(track: tracks[0], queue: tracks)
                                } label: {
                                    Label("Play Top Mix", systemImage: "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 36)

                            let topTracksQueue = summary.topTracks.map(\.track)
                            LazyVStack(spacing: 4) {
                                ForEach(Array(summary.topTracks.prefix(15).enumerated()), id: \.element.id) { idx, ranked in
                                    BCStandardTrackRow(
                                        track: ranked.track,
                                        index: idx + 1,
                                        showArtwork: true,
                                        showAlbumColumn: true,
                                        queueContext: topTracksQueue,
                                        trailingBadge: "\(ranked.playCount) \(ranked.playCount == 1 ? "play" : "plays")"
                                    )
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                    }

                    // Top Artists Grid
                    if !summary.topArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Top Artists")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 36)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 20) {
                                    ForEach(Array(summary.topArtists.prefix(12).enumerated()), id: \.element.id) { idx, ranked in
                                        Button {
                                            if let artistId = ranked.artistId, !artistId.isEmpty {
                                                appState.openDestination(.artistId(artistId))
                                            } else {
                                                appState.selectSidebar(.search)
                                                Task { await appState.performSearch(ranked.name) }
                                            }
                                        } label: {
                                            VStack(spacing: 8) {
                                                ZStack(alignment: .topLeading) {
                                                    ArtworkImage(url: ranked.artworkURL, size: 118, cornerRadius: 59, isCircle: true)
                                                    Text("#\(idx + 1)")
                                                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                                                        .foregroundStyle(accentFg)
                                                        .padding(.horizontal, 7)
                                                        .padding(.vertical, 3)
                                                        .background(Capsule().fill(accent))
                                                }
                                                Text(ranked.name)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                                    .lineLimit(1)
                                                Text("\(ranked.playCount) plays · \(Int(ranked.totalSeconds / 60))m")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                            }
                                            .frame(width: 128)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 36)
                            }
                        }
                    }

                    // Monthly Activity Mini Chart
                    if !summary.monthlyMinutes.isEmpty {
                        monthlyChartCard(summary.monthlyMinutes)
                            .padding(.horizontal, 36)
                    }

                    // Recently Played Timeline
                    if !appState.libraryStore.history.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recently Played Timeline")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 36)

                            let recent = Array(appState.libraryStore.history.prefix(20))
                            let recentTracks = recent.map(\.track)
                            LazyVStack(spacing: 2) {
                                ForEach(recent) { event in
                                    BCStandardTrackRow(
                                        track: event.track,
                                        showArtwork: true,
                                        showAlbumColumn: false,
                                        queueContext: recentTracks,
                                        trailingBadge: shortTimestamp(event.playedAt)
                                    )
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: historyCacheKey) {
            cachedSummary = appState.libraryStore.computeReplaySummary()
        }
    }

    private func monthlyChartCard(_ monthly: [String: Int]) -> some View {
        let sorted = monthly.sorted { $0.key < $1.key }.suffix(8)
        let maxMins = max(1, sorted.map(\.value).max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            Text("Monthly Listening (Minutes)")
                .font(.system(size: 16, weight: .bold))

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(sorted), id: \.key) { month, mins in
                    VStack(spacing: 6) {
                        Text("\(mins)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        SoundChordTheme.accentColor(for: colorScheme),
                                        SoundChordTheme.accentColor(for: colorScheme).opacity(0.45)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(12, CGFloat(mins) / CGFloat(maxMins) * 110))
                        Text(month)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 156, alignment: .bottom)
        }
        .padding(18)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
    }

    private func formatListeningMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return "\(h)h \(m)m"
        }
        return "\(minutes) min"
    }

    private func formatHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let suffix = normalized >= 12 ? "PM" : "AM"
        let display = normalized % 12 == 0 ? 12 : normalized % 12
        return "\(display):00 \(suffix)"
    }

    @MainActor
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func shortTimestamp(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ReplayStatCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(secondary)
                    .tracking(0.6)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
        .overlay(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }
}
