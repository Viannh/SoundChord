import SwiftUI

// MARK: - AlbumDetailView

public struct AlbumDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public let albumId: String
    public let initialAlbum: Album?

    @State private var album: Album?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var headerTint: Color = SoundChordTheme.accentColor.opacity(0.45)
    @State private var showFullDescription = false

    public init(albumId: String, initialAlbum: Album? = nil) {
        self.albumId = albumId
        self.initialAlbum = initialAlbum
    }

    private var displayedAlbum: Album? {
        album ?? initialAlbum
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let current = displayedAlbum {
                    albumHeroHeader(current)

                    if isLoading && current.tracks.isEmpty {
                        detailTracksSkeleton
                    } else if current.tracks.isEmpty {
                        BCEmptyStateView(
                            icon: "music.note",
                            title: "No Tracks Found",
                            message: loadError ?? "This album doesn't have playable tracks right now.",
                            buttonTitle: "Retry"
                        ) {
                            Task { await loadAlbum() }
                        }
                        .padding(.horizontal, 36)
                    } else {
                        albumTracksList(current)
                        albumFooter(current)
                    }
                } else if isLoading {
                    detailHeroSkeleton
                    detailTracksSkeleton
                } else {
                    BCEmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't Load Album",
                        message: loadError ?? "Unable to fetch album details.",
                        buttonTitle: "Retry"
                    ) {
                        Task { await loadAlbum() }
                    }
                    .padding(36)
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: albumId) {
            await loadAlbum()
        }
    }

    private func albumHeroHeader(_ item: Album) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Artwork-tinted gradient hero backdrop
            LinearGradient(
                colors: [
                    headerTint.opacity(0.55),
                    headerTint.opacity(0.22),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 28) {
                // 220pt Artwork with radiosity glow & shadow
                ZStack {
                    ArtworkImage(url: item.artworkURL, size: 220, cornerRadius: SoundChordTheme.cornerRadiusCard)
                        .blur(radius: 26)
                        .opacity(0.32)
                        .scaleEffect(0.90)
                        .offset(y: 12)

                    ArtworkImage(url: item.artworkURL, size: 220, cornerRadius: SoundChordTheme.cornerRadiusCard)
                        .shadow(color: .black.opacity(0.36), radius: 18, y: 8)
                }
                .frame(width: 220, height: 220)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ALBUM")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        .tracking(1.0)

                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 30, weight: .bold))
                            .lineLimit(2)
                        if item.isExplicit {
                            BCExplicitBadge()
                        }
                    }

                    // Artist link
                    if let artistId = item.artistId, !artistId.isEmpty {
                        Button {
                            appState.openDestination(.artistId(artistId))
                        } label: {
                            Text(item.artist)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(item.artist)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    }

                    // Metadata line
                    HStack(spacing: 6) {
                        if let year = item.year, !year.isEmpty {
                            Text(year)
                        }
                        if !item.tracks.isEmpty {
                            if item.year != nil { Text("·") }
                            Text("\(item.tracks.count) \(item.tracks.count == 1 ? "song" : "songs")")
                            if item.totalDuration > 0 {
                                Text("·")
                                Text(formatTotalDuration(item.totalDuration))
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))

                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                            .lineLimit(showFullDescription ? nil : 2)
                            .onTapGesture { showFullDescription.toggle() }
                    }

                    // Action Buttons
                    HStack(spacing: 12) {
                        Button {
                            appState.playAlbum(item, startingAt: 0, shuffled: false)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.tracks.isEmpty)

                        Button {
                            appState.playAlbum(item, startingAt: 0, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.tracks.isEmpty)

                        Button {
                            downloadAll(item.tracks)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Circle().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Download All Tracks")
                        .disabled(item.tracks.isEmpty)

                        Button {
                            saveCollectionAsPlaylist(title: item.title, tracks: item.tracks, artworkURL: item.artworkURL)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Circle().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Save Album to Library Playlist")
                        .disabled(item.tracks.isEmpty)
                    }
                    .padding(.top, 8)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    private func albumTracksList(_ item: Album) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#")
                    .frame(width: 26, alignment: .center)
                Text("TITLE")
                Spacer()
                Image(systemName: "clock")
                    .frame(width: 46, alignment: .trailing)
                Spacer().frame(width: 26)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .padding(.bottom, 6)

            Divider()
                .overlay(SoundChordTheme.hairline(for: colorScheme))
                .padding(.horizontal, 36)

            LazyVStack(spacing: 2) {
                ForEach(Array(item.tracks.enumerated()), id: \.element.id) { idx, track in
                    BCStandardTrackRow(
                        track: track,
                        index: idx + 1,
                        showArtwork: false,
                        showAlbumColumn: false,
                        queueContext: item.tracks
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func albumFooter(_ item: Album) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(SoundChordTheme.hairline(for: colorScheme))
                .padding(.bottom, 8)
            Text("\(item.tracks.count) songs · \(formatTotalDuration(item.totalDuration))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let year = item.year, !year.isEmpty {
                Text("Released \(year)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 36)
    }

    private func loadAlbum() async {
        if let initial = initialAlbum {
            album = initial
            Task {
                headerTint = await BCArtworkTintSampler.sampleTintColor(from: initial.artworkURL)
            }
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let fetched = try await appState.innerTube.fetchAlbum(browseId: albumId)
            album = fetched
            headerTint = await BCArtworkTintSampler.sampleTintColor(from: fetched.artworkURL ?? initialAlbum?.artworkURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func downloadAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        appState.showToast("Queuing \(tracks.count) tracks for download…")
        for track in tracks {
            if !track.isDownloaded && appState.libraryStore.localFileURL(for: track.id) == nil {
                appState.download(track)
            }
        }
    }

    private func saveCollectionAsPlaylist(title: String, tracks: [Track], artworkURL: URL?) {
        let created = appState.libraryStore.createPlaylist(title: title, description: "Saved from SoundChord")
        for track in tracks {
            appState.libraryStore.addToPlaylist(playlistId: created.id, track: track)
        }
        appState.showToast("Saved \"\(title)\" to Playlists")
    }
}

// MARK: - ArtistDetailView

public struct ArtistDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public let artistId: String
    public let initialArtist: Artist?

    @State private var artist: Artist?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var headerTint: Color = SoundChordTheme.accentColor.opacity(0.45)
    @State private var showAllTopSongs = false
    @State private var showFullBio = false

    public init(artistId: String, initialArtist: Artist? = nil) {
        self.artistId = artistId
        self.initialArtist = initialArtist
    }

    private var displayedArtist: Artist? {
        artist ?? initialArtist
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let current = displayedArtist {
                    artistHeroHeader(current)

                    if isLoading && current.topSongs.isEmpty && current.albums.isEmpty {
                        detailTracksSkeleton
                    } else {
                        // Top Songs
                        if !current.topSongs.isEmpty {
                            topSongsSection(current.topSongs)
                        }

                        // Albums Carousel
                        if !current.albums.isEmpty {
                            albumShelfSection(title: "Albums", albums: current.albums)
                        }

                        // Singles & EPs Carousel
                        if !current.singles.isEmpty {
                            albumShelfSection(title: "Singles & EPs", albums: current.singles)
                        }

                        // Related Artists
                        if !current.relatedArtists.isEmpty {
                            relatedArtistsSection(current.relatedArtists)
                        }

                        // About Bio
                        if let bio = current.description, !bio.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("About \(current.name)")
                                    .font(.system(size: 18, weight: .bold))
                                Text(bio)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(showFullBio ? nil : 4)
                                    .lineSpacing(3)
                                Button(showFullBio ? "Show Less" : "Read More") {
                                    withAnimation { showFullBio.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
                            .padding(.horizontal, 36)
                        }
                    }
                } else if isLoading {
                    detailHeroSkeleton
                    detailTracksSkeleton
                } else {
                    BCEmptyStateView(
                        icon: "person.crop.circle.badge.exclamationmark",
                        title: "Couldn't Load Artist",
                        message: loadError ?? "Unable to fetch artist details.",
                        buttonTitle: "Retry"
                    ) {
                        Task { await loadArtist() }
                    }
                    .padding(36)
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: artistId) {
            await loadArtist()
        }
    }

    private func artistHeroHeader(_ item: Artist) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    headerTint.opacity(0.62),
                    headerTint.opacity(0.24),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 28) {
                ArtworkImage(
                    url: item.artworkURL ?? item.bannerURL,
                    size: 200,
                    cornerRadius: 100,
                    isCircle: true
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ARTIST")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(1.0)

                    Text(item.name)
                        .font(.system(size: 38, weight: .bold))
                        .lineLimit(2)

                    if let subs = item.subscriberCount, !subs.isEmpty {
                        Text(subs)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if !item.topSongs.isEmpty {
                                appState.play(track: item.topSongs[0], queue: item.topSongs)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.topSongs.isEmpty)

                        Button {
                            if !item.topSongs.isEmpty {
                                var shuffled = item.topSongs
                                shuffled.shuffle()
                                appState.play(track: shuffled[0], queue: shuffled)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.topSongs.isEmpty)
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.top, 38)
            .padding(.bottom, 28)
        }
    }

    private func topSongsSection(_ songs: [Track]) -> some View {
        let visible = showAllTopSongs ? songs : Array(songs.prefix(5))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top Songs")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                if songs.count > 5 {
                    Button(showAllTopSongs ? "Show Less" : "See All (\(songs.count))") {
                        withAnimation { showAllTopSongs.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                }
            }
            .padding(.horizontal, 36)

            LazyVStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, track in
                    BCStandardTrackRow(
                        track: track,
                        index: idx + 1,
                        showArtwork: true,
                        showAlbumColumn: true,
                        queueContext: songs
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func albumShelfSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 36)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(albums) { album in
                        BCSquareCard(item: .album(album), size: 184)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 4)
            }
        }
    }

    private func relatedArtistsSection(_ related: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fans Also Like")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 36)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(related) { other in
                        BCArtistCircleCard(artist: other, size: 124)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 4)
            }
        }
    }

    private func loadArtist() async {
        if let initial = initialArtist {
            artist = initial
            Task {
                headerTint = await BCArtworkTintSampler.sampleTintColor(from: initial.artworkURL ?? initial.bannerURL)
            }
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let fetched = try await appState.innerTube.fetchArtist(browseId: artistId)
            artist = fetched
            headerTint = await BCArtworkTintSampler.sampleTintColor(from: fetched.artworkURL ?? fetched.bannerURL ?? initialArtist?.artworkURL)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - PlaylistDetailView

public struct PlaylistDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    public let playlistId: String
    public let initialPlaylist: Playlist?

    @State private var remotePlaylist: Playlist?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var headerTint: Color = SoundChordTheme.accentColor.opacity(0.45)

    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false

    public init(playlistId: String, initialPlaylist: Playlist? = nil) {
        self.playlistId = playlistId
        self.initialPlaylist = initialPlaylist
    }

    /// If this playlist is a user-created local playlist, always read live state from `LibraryStore`.
    private var localPlaylist: Playlist? {
        appState.libraryStore.playlists.first(where: { $0.id == playlistId })
    }

    private var displayedPlaylist: Playlist? {
        localPlaylist ?? remotePlaylist ?? initialPlaylist
    }

    private var isEditableLocal: Bool {
        localPlaylist != nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let current = displayedPlaylist {
                    playlistHeroHeader(current)

                    if isLoading && current.tracks.isEmpty && !isEditableLocal {
                        detailTracksSkeleton
                    } else if current.tracks.isEmpty {
                        BCEmptyStateView(
                            icon: "music.note.list",
                            title: isEditableLocal ? "Playlist is Empty" : "No Tracks Available",
                            message: isEditableLocal
                                ? "Right-click any song across SoundChord and choose \"Add to Playlist\" to build this playlist."
                                : (loadError ?? "This playlist currently has no playable tracks."),
                            buttonTitle: isEditableLocal ? "Explore Music" : "Retry"
                        ) {
                            if isEditableLocal {
                                appState.selectSidebar(.explore)
                            } else {
                                Task { await loadPlaylist() }
                            }
                        }
                        .padding(.horizontal, 36)
                    } else {
                        playlistTracksList(current)
                    }
                } else if isLoading {
                    detailHeroSkeleton
                    detailTracksSkeleton
                } else {
                    BCEmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't Load Playlist",
                        message: loadError ?? "Unable to fetch playlist details.",
                        buttonTitle: "Retry"
                    ) {
                        Task { await loadPlaylist() }
                    }
                    .padding(36)
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: playlistId) {
            await loadPlaylist()
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheetView
        }
        .alert("Delete Playlist?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.libraryStore.deletePlaylist(id: playlistId)
                appState.showToast("Deleted playlist")
                appState.selectSidebar(.library)
            }
        } message: {
            Text("This will permanently delete \"\(displayedPlaylist?.title ?? "this playlist")\" from your library.")
        }
    }

    private func playlistHeroHeader(_ item: Playlist) -> some View {
        let artworkURL = item.artworkURL ?? item.tracks.first?.artworkURL

        return ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    headerTint.opacity(0.55),
                    headerTint.opacity(0.22),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 28) {
                ZStack {
                    ArtworkImage(url: artworkURL, size: 220, cornerRadius: SoundChordTheme.cornerRadiusCard)
                        .blur(radius: 26)
                        .opacity(0.32)
                        .scaleEffect(0.90)
                        .offset(y: 12)

                    ArtworkImage(url: artworkURL, size: 220, cornerRadius: SoundChordTheme.cornerRadiusCard)
                        .shadow(color: .black.opacity(0.36), radius: 18, y: 8)
                }
                .frame(width: 220, height: 220)

                VStack(alignment: .leading, spacing: 8) {
                    Text(isEditableLocal ? "YOUR PLAYLIST" : "PLAYLIST")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        .tracking(1.0)

                    Text(item.title)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)

                    if let author = item.author, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    }

                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Text("\(item.tracks.count) \(item.tracks.count == 1 ? "song" : "songs")")
                        if item.totalDuration > 0 {
                            Text("·")
                            Text(formatTotalDuration(item.totalDuration))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))

                    HStack(spacing: 12) {
                        Button {
                            appState.playPlaylist(item, startingAt: 0, shuffled: false)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.tracks.isEmpty)

                        Button {
                            appState.playPlaylist(item, startingAt: 0, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.tracks.isEmpty)

                        Button {
                            downloadAll(item.tracks)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                .overlay(Circle().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Download All Tracks")
                        .disabled(item.tracks.isEmpty)

                        if isEditableLocal {
                            Button {
                                renameDraft = item.title
                                showRenameSheet = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Circle().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Rename Playlist")

                            Button {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Circle().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Delete Playlist")
                        } else {
                            Button {
                                let copy = appState.libraryStore.createPlaylist(title: item.title, description: item.description)
                                for track in item.tracks {
                                    appState.libraryStore.addToPlaylist(playlistId: copy.id, track: track)
                                }
                                appState.showToast("Saved \"\(item.title)\" to Library")
                            } label: {
                                Label("Save Copy", systemImage: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(item.tracks.isEmpty)
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    private func playlistTracksList(_ item: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#")
                    .frame(width: 26, alignment: .center)
                Spacer().frame(width: 40)
                Text("SONG")
                Spacer()
                Text("ALBUM")
                    .frame(maxWidth: 220, alignment: .leading)
                Image(systemName: "clock")
                    .frame(width: 46, alignment: .trailing)
                Spacer().frame(width: 26)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .padding(.bottom, 6)

            Divider()
                .overlay(SoundChordTheme.hairline(for: colorScheme))
                .padding(.horizontal, 36)

            LazyVStack(spacing: 2) {
                ForEach(Array(item.tracks.enumerated()), id: \.element.id) { idx, track in
                    BCStandardTrackRow(
                        track: track,
                        index: idx + 1,
                        showArtwork: true,
                        showAlbumColumn: true,
                        queueContext: item.tracks,
                        onRemoveFromPlaylist: isEditableLocal ? {
                            appState.libraryStore.removeFromPlaylist(playlistId: item.id, trackId: track.id)
                            appState.showToast("Removed \"\(track.title)\"")
                        } : nil
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var renameSheetView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Playlist")
                .font(.system(size: 18, weight: .bold))
            TextField("Playlist name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("Cancel") {
                    showRenameSheet = false
                }
                Button("Save") {
                    commitRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.libraryStore.renamePlaylist(id: playlistId, title: trimmed)
        appState.showToast("Renamed playlist to \"\(trimmed)\"")
        showRenameSheet = false
    }

    private func loadPlaylist() async {
        if let local = localPlaylist {
            headerTint = await BCArtworkTintSampler.sampleTintColor(from: local.artworkURL ?? local.tracks.first?.artworkURL)
            return
        }
        if let initial = initialPlaylist {
            remotePlaylist = initial
            Task {
                headerTint = await BCArtworkTintSampler.sampleTintColor(from: initial.artworkURL ?? initial.tracks.first?.artworkURL)
            }
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let fetched = try await appState.innerTube.fetchPlaylist(browseId: playlistId)
            remotePlaylist = fetched
            headerTint = await BCArtworkTintSampler.sampleTintColor(from: fetched.artworkURL ?? fetched.tracks.first?.artworkURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func downloadAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        appState.showToast("Queuing \(tracks.count) tracks for download…")
        for track in tracks {
            if !track.isDownloaded && appState.libraryStore.localFileURL(for: track.id) == nil {
                appState.download(track)
            }
        }
    }
}

// MARK: - Detail View Shared Skeletons & Formatters

private var detailHeroSkeleton: some View {
    HStack(alignment: .bottom, spacing: 28) {
        BCShimmerBox(cornerRadius: 12)
            .frame(width: 220, height: 220)
        VStack(alignment: .leading, spacing: 10) {
            BCShimmerBox(cornerRadius: 4).frame(width: 80, height: 12)
            BCShimmerBox(cornerRadius: 6).frame(width: 280, height: 28)
            BCShimmerBox(cornerRadius: 4).frame(width: 180, height: 18)
            HStack(spacing: 12) {
                BCShimmerBox(cornerRadius: 20).frame(width: 100, height: 38)
                BCShimmerBox(cornerRadius: 20).frame(width: 110, height: 38)
            }
            .padding(.top, 8)
        }
        Spacer()
    }
    .padding(.horizontal, 36)
    .padding(.top, 36)
}

private var detailTracksSkeleton: some View {
    VStack(spacing: 8) {
        ForEach(0..<8, id: \.self) { _ in
            HStack(spacing: 12) {
                BCShimmerBox(cornerRadius: 4).frame(width: 22, height: 12)
                BCShimmerBox(cornerRadius: 6).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    BCShimmerBox(cornerRadius: 4).frame(width: 210, height: 12)
                    BCShimmerBox(cornerRadius: 4).frame(width: 130, height: 10)
                }
                Spacer()
                BCShimmerBox(cornerRadius: 4).frame(width: 38, height: 10)
            }
            .padding(.horizontal, 36)
            .frame(height: 50)
        }
    }
}

private func formatTotalDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int((seconds / 60).rounded())
    let hours = totalMinutes / 60
    let mins = totalMinutes % 60
    if hours > 0 {
        return "\(hours) hr \(mins) min"
    }
    return "\(max(1, mins)) min"
}
