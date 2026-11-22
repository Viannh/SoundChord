import AppKit
import SwiftUI

// MARK: - Shared UI Components (BC-prefixed internal helpers for UI/Views)

struct BCExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
            )
            .accessibilityLabel("Explicit")
    }
}

struct BCWaveformBars: View {
    var isPlaying: Bool
    var color: Color = SoundChordTheme.accentColor
    var height: CGFloat = 14

    @State private var animate = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color)
                    .frame(
                        width: 2.5,
                        height: isPlaying
                            ? (animate ? barMaxHeight(idx) : barMinHeight(idx))
                            : height * 0.35
                    )
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: 0.42 + Double(idx) * 0.14).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: animate
                    )
            }
        }
        .frame(width: 14, height: height, alignment: .bottom)
        .onAppear {
            if isPlaying { animate = true }
        }
        .onChange(of: isPlaying) { _, playing in
            animate = playing
        }
    }

    private func barMaxHeight(_ index: Int) -> CGFloat {
        switch index {
        case 0: return height * 0.95
        case 1: return height * 0.65
        default: return height * 0.85
        }
    }

    private func barMinHeight(_ index: Int) -> CGFloat {
        switch index {
        case 0: return height * 0.25
        case 1: return height * 0.92
        default: return height * 0.32
        }
    }
}

struct BCShimmerBox: View {
    var cornerRadius: CGFloat = 8
    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.14),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(60, geo.size.width * 0.65))
                    .offset(x: shimmerPhase * geo.size.width * 1.4)
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.2
            }
        }
    }
}

struct BCTrackContextMenuItems: View {
    @EnvironmentObject var appState: AppState
    let track: Track
    var queueContext: [Track]? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil

    private var isLiked: Bool {
        appState.libraryStore.isLiked(track.id)
    }

    private var isDownloaded: Bool {
        track.isDownloaded || appState.libraryStore.localFileURL(for: track.id) != nil
    }

    var body: some View {
        Button {
            appState.play(track: track, queue: queueContext)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            appState.audioEngine.addToQueue(track, playNext: true)
            appState.showToast("Playing \"\(track.title)\" next")
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            appState.audioEngine.addToQueue(track, playNext: false)
            appState.showToast("Added \"\(track.title)\" to queue")
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        Button {
            appState.libraryStore.toggleLike(track)
            appState.showToast(isLiked ? "Removed from Liked Songs" : "Added to Liked Songs")
        } label: {
            Label(
                isLiked ? "Remove from Liked Songs" : "Add to Liked Songs",
                systemImage: isLiked ? "heart.slash" : "heart"
            )
        }

        Menu {
            if appState.libraryStore.playlists.isEmpty {
                Button {
                    let created = appState.libraryStore.createPlaylist(title: "My Playlist", description: nil)
                    appState.libraryStore.addToPlaylist(playlistId: created.id, track: track)
                    appState.showToast("Added to \"\(created.title)\"")
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
            } else {
                ForEach(appState.libraryStore.playlists) { playlist in
                    Button {
                        appState.libraryStore.addToPlaylist(playlistId: playlist.id, track: track)
                        appState.showToast("Added to \"\(playlist.title)\"")
                    } label: {
                        Text(playlist.title)
                    }
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        if let onRemoveFromPlaylist {
            Button(role: .destructive) {
                onRemoveFromPlaylist()
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }

        if !track.isLocal {
            Divider()
            if isDownloaded {
                Button(role: .destructive) {
                    appState.deleteDownload(track)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else {
                Button {
                    appState.download(track)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }

        if track.artistId != nil || track.albumId != nil {
            Divider()
            if let artistId = track.artistId, !artistId.isEmpty {
                Button {
                    appState.openDestination(.artistId(artistId))
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
            }
            if let albumId = track.albumId, !albumId.isEmpty {
                Button {
                    appState.openDestination(.albumId(albumId))
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
    }
}

struct BCEmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String
    let message: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(secondary)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(primary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let buttonTitle, let action {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentFg)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
    }
}

// MARK: - Square Card Lockup (184pt Apple Music / Spotify Style)

struct BCSquareCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: ShelfItem
    var size: CGFloat = 184

    @State private var isHovered = false
    @State private var isResolvingPlay = false

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ArtworkImage(url: item.artworkURL, size: size, cornerRadius: SoundChordTheme.cornerRadiusCard, isCircle: false)
                    .shadow(color: Color.black.opacity(isHovered ? 0.30 : 0.16), radius: isHovered ? 10 : 5, y: isHovered ? 5 : 2)

                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.28 : 0.0))
                    .animation(.easeInOut(duration: 0.14), value: isHovered)

                if isHovered || isResolvingPlay {
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                quickPlay()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(accent)
                                        .frame(width: 34, height: 34)
                                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                                    if isResolvingPlay {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(accentFg)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(accentFg)
                                            .offset(x: 1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Menu {
                                cardMenuItems
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.black.opacity(0.62))
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.75)
                                        )
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 30, height: 30)
                        }
                        .padding(10)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
            .onTapGesture {
                openItem()
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    if isExplicit {
                        BCExplicitBadge()
                    }
                }
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
        }
        .frame(width: size)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            cardMenuItems
        }
    }

    private var isExplicit: Bool {
        switch item {
        case .track(let t): return t.isExplicit
        case .album(let a): return a.isExplicit
        default: return false
        }
    }

    @ViewBuilder
    private var cardMenuItems: some View {
        switch item {
        case .track(let track):
            BCTrackContextMenuItems(track: track)
        case .album(let album):
            Button {
                quickPlay()
            } label: {
                Label("Play Album", systemImage: "play.fill")
            }
            Button {
                appState.openDestination(.album(album))
            } label: {
                Label("View Album", systemImage: "square.stack")
            }
            if let artistId = album.artistId, !artistId.isEmpty {
                Button {
                    appState.openDestination(.artistId(artistId))
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
            }
        case .playlist(let playlist):
            Button {
                quickPlay()
            } label: {
                Label("Play Playlist", systemImage: "play.fill")
            }
            Button {
                appState.openDestination(.playlist(playlist))
            } label: {
                Label("View Playlist", systemImage: "music.note.list")
            }
        case .artist(let artist):
            Button {
                appState.openDestination(.artist(artist))
            } label: {
                Label("View Artist", systemImage: "person.circle")
            }
        }
    }

    private func openItem() {
        switch item {
        case .track(let track):
            appState.play(track: track)
        case .album(let album):
            appState.openDestination(.album(album))
        case .artist(let artist):
            appState.openDestination(.artist(artist))
        case .playlist(let playlist):
            appState.openDestination(.playlist(playlist))
        }
    }

    private func quickPlay() {
        switch item {
        case .track(let track):
            appState.play(track: track)
        case .album(let album):
            if !album.tracks.isEmpty {
                appState.playAlbum(album)
            } else {
                isResolvingPlay = true
                Task {
                    defer { isResolvingPlay = false }
                    if let full = try? await appState.innerTube.fetchAlbum(browseId: album.id), !full.tracks.isEmpty {
                        appState.playAlbum(full)
                    } else {
                        appState.openDestination(.album(album))
                    }
                }
            }
        case .playlist(let playlist):
            if !playlist.tracks.isEmpty {
                appState.playPlaylist(playlist)
            } else {
                isResolvingPlay = true
                Task {
                    defer { isResolvingPlay = false }
                    if let full = try? await appState.innerTube.fetchPlaylist(browseId: playlist.id), !full.tracks.isEmpty {
                        appState.playPlaylist(full)
                    } else {
                        appState.openDestination(.playlist(playlist))
                    }
                }
            }
        case .artist(let artist):
            if !artist.topSongs.isEmpty {
                appState.play(track: artist.topSongs[0], queue: artist.topSongs)
            } else {
                isResolvingPlay = true
                Task {
                    defer { isResolvingPlay = false }
                    if let full = try? await appState.innerTube.fetchArtist(browseId: artist.id), !full.topSongs.isEmpty {
                        appState.play(track: full.topSongs[0], queue: full.topSongs)
                    } else {
                        appState.openDestination(.artist(artist))
                    }
                }
            }
        }
    }
}

// MARK: - Circular Artist Card (124pt)

struct BCArtistCircleCard: View {
    @EnvironmentObject var appState: AppState
    let artist: Artist
    var size: CGFloat = 124

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.openDestination(.artist(artist))
        } label: {
            VStack(spacing: 8) {
                ArtworkImage(url: artist.artworkURL, size: size, cornerRadius: size / 2, isCircle: true)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(isHovered ? 0.30 : 0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isHovered ? 0.35 : 0.18), radius: isHovered ? 10 : 5, y: 4)
                    .scaleEffect(isHovered ? 1.03 : 1.0)

                VStack(spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subs = artist.subscriberCount, !subs.isEmpty {
                        Text(subs)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: size + 12)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Quick Pick Track Row (Apple Music 4-Row Horizontal Grid Cell)

struct BCQuickPickRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let track: Track
    let queueContext: [Track]

    @State private var isHovered = false

    private var isCurrent: Bool {
        appState.audioEngine.currentTrack?.id == track.id
    }

    private var isLiked: Bool {
        appState.libraryStore.isLiked(track.id)
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)

        return HStack(spacing: 12) {
            ZStack {
                ArtworkImage(url: track.artworkURL, size: 44, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)
                if isHovered || isCurrent {
                    RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                    if isCurrent && appState.audioEngine.isPlaying && !isHovered {
                        BCWaveformBars(isPlaying: true, color: .white, height: 14)
                    } else {
                        Image(systemName: isCurrent && appState.audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? accent : primary)
                        .lineLimit(1)
                    if track.isExplicit {
                        BCExplicitBadge()
                    }
                }
                HStack(spacing: 4) {
                    Text(track.artist)
                        .lineLimit(1)
                    if let album = track.album, !album.isEmpty {
                        Text("·")
                        Text(album)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(secondary)
            }

            Spacer(minLength: 4)

            if isHovered || isLiked {
                Button {
                    appState.libraryStore.toggleLike(track)
                } label: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(isLiked ? accent : secondary)
                }
                .buttonStyle(.plain)
                .help(isLiked ? "Unlike" : "Like")
            }

            if isHovered {
                Menu {
                    BCTrackContextMenuItems(track: track, queueContext: queueContext)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
            } else if track.duration > 0 {
                Text(track.formattedDuration)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 310, height: 58)
        .background(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .fill(isHovered ? hoverBg : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
        .onTapGesture {
            if isCurrent {
                appState.audioEngine.togglePlayPause()
            } else {
                appState.play(track: track, queue: queueContext)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            BCTrackContextMenuItems(track: track, queueContext: queueContext)
        }
    }
}

// MARK: - Editorial Hero Card

struct BCHeroCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: ShelfItem
    @State private var isHovered = false

    var body: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return VStack(alignment: .leading, spacing: 6) {
            Text(item.kindLabel.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondary)
                .tracking(0.6)

            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(1)

            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: item.artworkURL, size: 340, cornerRadius: SoundChordTheme.cornerRadiusCard)
                    .frame(width: 340, height: 196)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))

                HStack(alignment: .bottom) {
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                .padding(14)
            }
            .frame(width: 340, height: 196)
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.14), radius: isHovered ? 10 : 5, y: 3)
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .frame(width: 340)
        .contentShape(Rectangle())
        .onTapGesture {
            switch item {
            case .track(let t): appState.play(track: t)
            case .album(let a): appState.openDestination(.album(a))
            case .artist(let a): appState.openDestination(.artist(a))
            case .playlist(let p): appState.openDestination(.playlist(p))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Mood / Genre Pill Chip

struct BCMoodChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let accentColor: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: isHovered)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return Button(action: action) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(accentColor)
                    .frame(width: 4, height: 22)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 138)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(isHovered ? accentColor.opacity(0.18) : cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shelf Section Renderer

struct BCShelfSectionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let shelf: ShelfSection

    private static let moodPalette: [Color] = [
        SoundChordTheme.accentColor,
        Color(red: 0.20, green: 0.62, blue: 0.98),
        Color(red: 0.68, green: 0.32, blue: 0.96),
        Color(red: 0.18, green: 0.78, blue: 0.56),
        Color(red: 0.98, green: 0.58, blue: 0.18),
        Color(red: 0.95, green: 0.30, blue: 0.62),
        Color(red: 0.35, green: 0.45, blue: 0.96),
        Color(red: 0.92, green: 0.74, blue: 0.16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section Header
            HStack(alignment: .firstTextBaseline) {
                Button {
                    appState.openDestination(.shelf(shelf))
                } label: {
                    HStack(spacing: 5) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                                Text(subtitle.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text(shelf.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if shelf.style == .trackList {
                    let tracks = shelf.items.compactMap { item -> Track? in
                        if case .track(let t) = item { return t }
                        return nil
                    }
                    if !tracks.isEmpty {
                        Button {
                            appState.play(track: tracks[0], queue: tracks)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SoundChordTheme.accentColor(for: colorScheme).opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 36)

            // Shelf Body
            switch shelf.style {
            case .trackList:
                quickPicksGrid
            case .artists:
                artistsCarousel
            case .hero:
                heroCarousel
            case .moodChips:
                moodChipsGrid
            case .squareGrid:
                squareCarousel
            }
        }
    }

    private var quickPicksGrid: some View {
        let tracks = shelf.items.compactMap { item -> Track? in
            if case .track(let t) = item { return t }
            return nil
        }
        let rows = Array(repeating: GridItem(.fixed(58), spacing: 6), count: min(4, max(1, tracks.count)))

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 18) {
                ForEach(tracks) { track in
                    BCQuickPickRow(track: track, queueContext: tracks)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 2)
        }
    }

    private var squareCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(shelf.items) { item in
                    BCSquareCard(item: item, size: 184)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 4)
        }
    }

    private var artistsCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 20) {
                ForEach(shelf.items) { item in
                    if case .artist(let artist) = item {
                        BCArtistCircleCard(artist: artist, size: 124)
                    } else {
                        BCSquareCard(item: item, size: 150)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 4)
        }
    }

    private var heroCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 20) {
                ForEach(shelf.items) { item in
                    BCHeroCard(item: item)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 4)
        }
    }

    private var moodChipsGrid: some View {
        let rows = [GridItem(.fixed(42), spacing: 10), GridItem(.fixed(42), spacing: 10)]
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 10) {
                ForEach(Array(shelf.items.enumerated()), id: \.element.id) { idx, item in
                    let color = Self.moodPalette[idx % Self.moodPalette.count]
                    BCMoodChip(title: item.title, accentColor: color) {
                        switch item {
                        case .playlist(let p):
                            appState.openDestination(.playlist(p))
                        case .album(let a):
                            appState.openDestination(.album(a))
                        case .artist(let a):
                            appState.openDestination(.artist(a))
                        case .track(let t):
                            appState.play(track: t)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - HomeView

public struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default: return "Late Night Listening"
        }
    }

    private var recentUniqueTracks: [Track] {
        var seen = Set<String>()
        var tracks: [Track] = []
        for event in appState.libraryStore.history {
            if seen.insert(event.track.id).inserted {
                tracks.append(event.track)
                if tracks.count >= 12 { break }
            }
        }
        return tracks
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .tracking(0.8)
                        Text("Home")
                            .font(.system(size: 34, weight: .bold))
                    }

                    Spacer()

                    Button {
                        Task { await appState.loadHome(force: true) }
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isLoadingHome {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text("Refresh")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                        .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isLoadingHome)
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                // Recently Played Shortcut Shelf
                if !recentUniqueTracks.isEmpty {
                    recentlyPlayedShelf
                }

                // Main Content
                if appState.isLoadingHome && appState.homeShelves.isEmpty {
                    homeSkeleton
                } else if appState.homeShelves.isEmpty {
                    BCEmptyStateView(
                        icon: "wifi.slash",
                        title: "Couldn't Load Home Feed",
                        message: appState.errorBanner ?? "Check your internet connection or try refreshing. Your Downloads and Local Music remain available offline.",
                        buttonTitle: "Retry"
                    ) {
                        Task { await appState.loadHome(force: true) }
                    }
                    .padding(.horizontal, 36)
                } else {
                    ForEach(appState.homeShelves) { shelf in
                        BCShelfSectionView(shelf: shelf)
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .task {
            await appState.loadHome(force: false)
        }
    }

    private var recentlyPlayedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Played")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    appState.selectSidebar(.library)
                } label: {
                    Text("See Library")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 36)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(recentUniqueTracks) { track in
                        BCSquareCard(item: .track(track), size: 148)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 2)
            }
        }
    }

    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Quick Picks skeleton
            VStack(alignment: .leading, spacing: 12) {
                BCShimmerBox(cornerRadius: 6)
                    .frame(width: 160, height: 20)
                    .padding(.horizontal, 36)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(spacing: 8) {
                                ForEach(0..<4, id: \.self) { _ in
                                    HStack(spacing: 12) {
                                        BCShimmerBox(cornerRadius: 6)
                                            .frame(width: 44, height: 44)
                                        VStack(alignment: .leading, spacing: 6) {
                                            BCShimmerBox(cornerRadius: 4)
                                                .frame(width: 170, height: 12)
                                            BCShimmerBox(cornerRadius: 4)
                                                .frame(width: 110, height: 10)
                                        }
                                        Spacer()
                                    }
                                    .frame(width: 310, height: 54)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }

            // Card Carousels skeleton
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    BCShimmerBox(cornerRadius: 6)
                        .frame(width: 210, height: 20)
                        .padding(.horizontal, 36)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(0..<6, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    BCShimmerBox(cornerRadius: 8)
                                        .frame(width: 184, height: 184)
                                    BCShimmerBox(cornerRadius: 4)
                                        .frame(width: 140, height: 12)
                                    BCShimmerBox(cornerRadius: 4)
                                        .frame(width: 96, height: 10)
                                }
                            }
                        }
                        .padding(.horizontal, 36)
                    }
                }
            }
        }
    }
}

// MARK: - ExploreView

public struct ExploreView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private static let curatedMoods: [(String, Color)] = [
        ("Chill", Color(red: 0.24, green: 0.64, blue: 0.96)),
        ("Focus", Color(red: 0.38, green: 0.48, blue: 0.96)),
        ("Workout", SoundChordTheme.accentColor),
        ("Energize", Color(red: 0.98, green: 0.56, blue: 0.16)),
        ("Feel Good", Color(red: 0.96, green: 0.72, blue: 0.16)),
        ("Party", Color(red: 0.72, green: 0.30, blue: 0.96)),
        ("Romance", Color(red: 0.96, green: 0.32, blue: 0.58)),
        ("Sleep", Color(red: 0.26, green: 0.34, blue: 0.72)),
        ("Commute", Color(red: 0.16, green: 0.76, blue: 0.56)),
        ("Hip-Hop", Color(red: 0.92, green: 0.38, blue: 0.24)),
        ("Indie & Alt", Color(red: 0.32, green: 0.72, blue: 0.68)),
        ("Electronic", Color(red: 0.56, green: 0.32, blue: 0.96))
    ]

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DISCOVER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .tracking(0.8)
                        Text("Explore")
                            .font(.system(size: 34, weight: .bold))
                    }

                    Spacer()

                    Button {
                        Task { await appState.loadExplore(force: true) }
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isLoadingExplore {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text("Refresh")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                        .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isLoadingExplore)
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                // Moods & Genres Quick Pills (when feed doesn't already include moodChips)
                if !appState.exploreShelves.contains(where: { $0.style == .moodChips }) {
                    moodsQuickSection
                }

                if appState.isLoadingExplore && appState.exploreShelves.isEmpty {
                    exploreSkeleton
                } else if appState.exploreShelves.isEmpty {
                    BCEmptyStateView(
                        icon: "sparkles",
                        title: "Explore Unavailable",
                        message: appState.errorBanner ?? "Unable to reach YouTube Music right now. Tap Retry to try again.",
                        buttonTitle: "Retry"
                    ) {
                        Task { await appState.loadExplore(force: true) }
                    }
                    .padding(.horizontal, 36)
                } else {
                    ForEach(appState.exploreShelves) { shelf in
                        BCShelfSectionView(shelf: shelf)
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .task {
            await appState.loadExplore(force: false)
        }
    }

    private var moodsQuickSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Moods & Genres")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 36)

            let rows = [GridItem(.fixed(42), spacing: 10), GridItem(.fixed(42), spacing: 10)]
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 10) {
                    ForEach(Self.curatedMoods, id: \.0) { mood, color in
                        BCMoodChip(title: mood, accentColor: color) {
                            appState.searchQuery = "\(mood) music"
                            appState.selectSidebar(.search)
                            Task { await appState.performSearch("\(mood) music") }
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 2)
            }
        }
    }

    private var exploreSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    BCShimmerBox(cornerRadius: 6)
                        .frame(width: 190, height: 20)
                        .padding(.horizontal, 36)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(0..<6, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    BCShimmerBox(cornerRadius: 8)
                                        .frame(width: 184, height: 184)
                                    BCShimmerBox(cornerRadius: 4)
                                        .frame(width: 140, height: 12)
                                    BCShimmerBox(cornerRadius: 4)
                                        .frame(width: 90, height: 10)
                                }
                            }
                        }
                        .padding(.horizontal, 36)
                    }
                }
            }
        }
    }
}

// MARK: - ShelfDetailView

public struct ShelfDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    public let shelf: ShelfSection

    public init(shelf: ShelfSection) {
        self.shelf = shelf
    }

    private var shelfTracks: [Track] {
        shelf.items.compactMap { item in
            if case .track(let track) = item { return track }
            return nil
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                            Text(subtitle.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(shelf.title)
                            .font(.system(size: 34, weight: .bold))
                    }
                    Spacer()
                    if !shelfTracks.isEmpty {
                        Button {
                            appState.play(track: shelfTracks[0], queue: shelfTracks)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                switch shelf.style {
                case .trackList:
                    LazyVStack(spacing: 4) {
                        ForEach(Array(shelfTracks.enumerated()), id: \.element.id) { index, track in
                            BCStandardTrackRow(
                                track: track,
                                index: index + 1,
                                showArtwork: true,
                                queueContext: shelfTracks
                            )
                        }
                    }
                    .padding(.horizontal, 28)

                case .artists:
                    let columns = [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 20)]
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(shelf.items) { item in
                            if case .artist(let artist) = item {
                                BCArtistCircleCard(artist: artist, size: 130)
                            } else {
                                BCSquareCard(item: item, size: 150)
                            }
                        }
                    }
                    .padding(.horizontal, 36)

                case .moodChips:
                    let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)]
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(shelf.items.enumerated()), id: \.element.id) { idx, item in
                            let hue = Double((idx * 47) % 360) / 360.0
                            BCMoodChip(title: item.title, accentColor: Color(hue: hue, saturation: 0.72, brightness: 0.88)) {
                                switch item {
                                case .playlist(let p): appState.openDestination(.playlist(p))
                                case .album(let a): appState.openDestination(.album(a))
                                case .artist(let a): appState.openDestination(.artist(a))
                                case .track(let t): appState.play(track: t)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 36)

                default:
                    let columns = [GridItem(.adaptive(minimum: 184, maximum: 210), spacing: 20)]
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(shelf.items) { item in
                            BCSquareCard(item: item, size: 184)
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }
            .padding(.bottom, 110)
        }
    }
}

// MARK: - Standard Full-Width Track Row (54pt, shared by ShelfDetail, Search, DetailViews, Library)

struct BCStandardTrackRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let track: Track
    var index: Int? = nil
    var showArtwork: Bool = true
    var showAlbumColumn: Bool = true
    var queueContext: [Track]? = nil
    var trailingBadge: String? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil

    @State private var isHovered = false

    private var isCurrent: Bool {
        appState.audioEngine.currentTrack?.id == track.id
    }

    private var isLiked: Bool {
        appState.libraryStore.isLiked(track.id)
    }

    private var isDownloaded: Bool {
        track.isDownloaded || appState.libraryStore.localFileURL(for: track.id) != nil
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)

        return HStack(spacing: 12) {
            // Optional Index / Play / Waveform column
            if let index {
                ZStack {
                    if isHovered {
                        Image(systemName: isCurrent && appState.audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isCurrent ? accent : primary)
                    } else if isCurrent {
                        BCWaveformBars(isPlaying: appState.audioEngine.isPlaying, color: accent, height: 13)
                    } else {
                        Text("\(index)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(secondary)
                    }
                }
                .frame(width: 26, alignment: .center)
            }

            // Artwork (40x40 radius 6pt)
            if showArtwork {
                ZStack {
                    ArtworkImage(url: track.artworkURL, size: 40, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)
                    if index == nil && (isHovered || isCurrent) {
                        RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        if isCurrent && appState.audioEngine.isPlaying && !isHovered {
                            BCWaveformBars(isPlaying: true, color: .white, height: 13)
                        } else {
                            Image(systemName: isCurrent && appState.audioEngine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 40, height: 40)
            }

            // Title & Artist
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? accent : primary)
                        .lineLimit(1)
                    if track.isExplicit {
                        BCExplicitBadge()
                    }
                    if isDownloaded && !track.isLocal {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(secondary)
                            .help("Downloaded for offline playback")
                    }
                }

                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

            // Optional Album Column
            if showAlbumColumn, let album = track.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            // Optional Quality / Format Badge
            if let trailingBadge, !trailingBadge.isEmpty {
                Text(trailingBadge)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }

            // Like Button
            Button {
                appState.libraryStore.toggleLike(track)
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(isLiked ? accent : secondary)
                    .opacity(isHovered || isLiked ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 24)

            // Duration
            Text(track.duration > 0 ? track.formattedDuration : "--")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(secondary)
                .frame(width: 46, alignment: .trailing)

            // Context Menu Trigger
            Menu {
                BCTrackContextMenuItems(
                    track: track,
                    queueContext: queueContext,
                    onRemoveFromPlaylist: onRemoveFromPlaylist
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(secondary)
                    .frame(width: 26, height: 26)
                    .opacity(isHovered ? 1 : 0.45)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .fill(
                    isCurrent
                        ? accent.opacity(isHovered ? 0.16 : 0.10)
                        : (isHovered ? hoverBg : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
        .onTapGesture {
            if isCurrent {
                appState.audioEngine.togglePlayPause()
            } else {
                appState.play(track: track, queue: queueContext)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            BCTrackContextMenuItems(
                track: track,
                queueContext: queueContext,
                onRemoveFromPlaylist: onRemoveFromPlaylist
            )
        }
    }
}

// MARK: - Artwork Dominant Tint Sampler (for DetailViews Hero Headers)

enum BCArtworkTintSampler {
    static func sampleTintColor(from url: URL?) async -> Color {
        guard let url else { return SoundChordTheme.accentColor.opacity(0.45) }
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (fetched, _) = try await URLSession.shared.data(from: url)
                data = fetched
            }
            guard let image = NSImage(data: data),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return SoundChordTheme.accentColor.opacity(0.45)
            }
            return await Task.detached(priority: .utility) {
                extractAverageColor(from: cgImage)
            }.value
        } catch {
            return SoundChordTheme.accentColor.opacity(0.45)
        }
    }

    private static func extractAverageColor(from cgImage: CGImage) -> Color {
        let size = 8
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
            return SoundChordTheme.accentColor.opacity(0.45)
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        let total = Double(size * size)
        for i in 0..<(size * size) {
            rSum += Double(pixels[i * 4]) / 255.0
            gSum += Double(pixels[i * 4 + 1]) / 255.0
            bSum += Double(pixels[i * 4 + 2]) / 255.0
        }
        let nsColor = NSColor(calibratedRed: rSum / total, green: gSum / total, blue: bSum / total, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let boosted = NSColor(
            calibratedHue: h,
            saturation: min(0.92, max(s * 1.25, 0.28)),
            brightness: min(0.75, max(v, 0.25)),
            alpha: 1.0
        )
        return Color(
            red: Double(boosted.redComponent),
            green: Double(boosted.greenComponent),
            blue: Double(boosted.blueComponent)
        )
    }
}
