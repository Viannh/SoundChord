import SwiftUI

public struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNewPlaylistSheet = false
    @State private var newPlaylistTitle = ""
    @State private var newPlaylistDescription = ""
    @State private var renamingPlaylist: Playlist?
    @State private var renameText = ""

    public init() {}

    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { SoundChordTheme.accentColor(for: colorScheme) }
    private var accentFg: Color { SoundChordTheme.accentForeground(for: colorScheme) }
    private var primaryText: Color { SoundChordTheme.primaryText(for: colorScheme) }
    private var secondaryText: Color { SoundChordTheme.secondaryText(for: colorScheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.top, isDark ? 30 : 36)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            quickSearchButton
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionGroup(title: "Discover") {
                        navRow(item: .home)
                        navRow(item: .explore)
                        navRow(item: .search)
                    }

                    sectionGroup(title: "Library") {
                        navRow(item: .library, badge: likedBadgeText)
                        navRow(item: .downloads, badge: downloadsBadgeText, isActiveBadge: hasActiveDownloads)
                        navRow(item: .localMusic, badge: localBadgeText)
                        navRow(item: .replay)
                    }

                    playlistsSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }

            Divider()
                .overlay(SoundChordTheme.hairline(for: colorScheme))

            footerSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background {
            sidebarBackground
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            newPlaylistSheet
        }
        .sheet(item: $renamingPlaylist) { playlist in
            renamePlaylistSheet(playlist: playlist)
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if isDark {
            SoundChordTheme.panelBackground(for: .dark)
        } else {
            // Light Mode Glass Element #1: .sidebar VisualEffectBlur + #F5F5F7 tint
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                SoundChordTheme.lightGlassTint(opacity: appState.libraryStore.settings.glassOpacity * 0.72)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDark
                                ? [SoundChordTheme.darkAccent, SoundChordTheme.darkAccent.opacity(0.85)]
                                : [SoundChordTheme.lightVibrantAccent, SoundChordTheme.lightAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accentFg)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("SoundChord")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("macOS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .tracking(0.4)
            }

            Spacer()
        }
    }

    // MARK: - Quick Search Trigger

    private var quickSearchButton: some View {
        Button {
            appState.selectSidebar(.search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(secondaryText)

                Text("Search")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(secondaryText)

                Spacer()

                Text("⌘F")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(isDark ? 0.10 : 0.06))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? SoundChordTheme.cardBackground(for: .dark) : Color.black.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections & Rows

    private func sectionGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(secondaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            content()
        }
    }

    private func navRow(
        item: SidebarItem,
        customTitle: String? = nil,
        badge: String? = nil,
        isActiveBadge: Bool = false
    ) -> some View {
        let isSelected = appState.selectedSidebar == item
        return SidebarNavButton(
            title: customTitle ?? item.title,
            systemImage: item.systemImage,
            isSelected: isSelected,
            badge: badge,
            isActiveBadge: isActiveBadge
        ) {
            appState.selectSidebar(item)
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Playlists")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(secondaryText)

                Spacer()

                Button {
                    appState.showImportPlaylistSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Import Playlist from URL or File")

                Button {
                    newPlaylistTitle = ""
                    newPlaylistDescription = ""
                    showNewPlaylistSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Playlist")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            Button {
                appState.showImportPlaylistSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 20, alignment: .center)
                    Text("Import Playlist")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if appState.libraryStore.playlists.isEmpty {
                Button {
                    newPlaylistTitle = ""
                    newPlaylistDescription = ""
                    showNewPlaylistSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(accent)
                            .frame(width: 20, alignment: .center)
                        Text("New Playlist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(appState.libraryStore.playlists) { playlist in
                    navRow(
                        item: .playlist(playlist.id),
                        customTitle: playlist.title,
                        badge: playlist.tracks.isEmpty ? nil : "\(playlist.tracks.count)"
                    )
                    .contextMenu {
                        Button("Play") {
                            appState.playPlaylist(playlist)
                        }
                        .disabled(playlist.tracks.isEmpty)

                        Button("Shuffle") {
                            appState.playPlaylist(playlist, shuffled: true)
                        }
                        .disabled(playlist.tracks.isEmpty)

                        Divider()

                        Button("Rename...") {
                            renameText = playlist.title
                            renamingPlaylist = playlist
                        }

                        Button("Delete Playlist", role: .destructive) {
                            if appState.selectedSidebar == .playlist(playlist.id) {
                                appState.selectSidebar(.library)
                            }
                            appState.libraryStore.deletePlaylist(id: playlist.id)
                            appState.showToast("Deleted \"\(playlist.title)\"")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            navRow(
                item: .addons,
                badge: addonsBadgeText,
                isActiveBadge: enabledAddonsCount > 0
            )
            navRow(item: .settings)

            HStack(spacing: 6) {
                Button {
                    appState.selectSidebar(.settings)
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(discordIndicatorColor)
                                .frame(width: 7, height: 7)
                            Text(discordLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        let signedIn = !appState.libraryStore.settings.ytCookieHeader.isEmpty
                        HStack(spacing: 4) {
                            Image(systemName: signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                                .font(.system(size: 11.5))
                                .foregroundStyle(signedIn ? accent : secondaryText)
                            Text(signedIn ? "Signed In" : "Guest")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(signedIn ? primaryText : secondaryText)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(isDark ? 0.08 : 0.06))
                        )
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Configure Discord RPC and YouTube Music account in Settings")

                compactThemeSwitcherButton
            }
        }
    }

    private var compactThemeSwitcherButton: some View {
        let mode = appState.libraryStore.settings.themeMode
        let iconName: String = {
            switch mode {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.stars.fill"
            }
        }()

        return Button {
            let nextMode: ThemeMode = isDark ? .light : .dark
            appState.updateSettings { $0.themeMode = nextMode }
            appState.showToast(nextMode == .dark ? "Switched to Spotify Dark" : "Switched to Apple Music Light")
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isDark ? 0.09 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .help("Switch Theme (Apple Music Light / Spotify Dark)")
        .contextMenu {
            Button("System Appearance") {
                appState.updateSettings { $0.themeMode = .system }
            }
            Button("Apple Music (Light)") {
                appState.updateSettings { $0.themeMode = .light }
            }
            Button("Spotify (Dark)") {
                appState.updateSettings { $0.themeMode = .dark }
            }
        }
    }

    // MARK: - Sheets

    private var newPlaylistSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Playlist")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    showNewPlaylistSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryText)
                TextField("My Playlist", text: $newPlaylistTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description (optional)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondaryText)
                TextField("Add a short note...", text: $newPlaylistDescription)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewPlaylistSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    createPlaylist()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func renamePlaylistSheet(playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Playlist")
                .font(.system(size: 18, weight: .bold))

            TextField("Playlist Name", text: $renameText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    renamingPlaylist = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        appState.libraryStore.renamePlaylist(id: playlist.id, title: trimmed)
                        appState.showToast("Renamed to \"\(trimmed)\"")
                    }
                    renamingPlaylist = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 340)
    }

    private func createPlaylist() {
        let trimmed = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let desc = newPlaylistDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = appState.libraryStore.createPlaylist(
            title: trimmed,
            description: desc.isEmpty ? nil : desc
        )
        showNewPlaylistSheet = false
        appState.selectSidebar(.playlist(created.id))
        appState.showToast("Created \"\(created.title)\"")
    }

    // MARK: - Computed Badges

    private var likedBadgeText: String? {
        let count = appState.libraryStore.likedTracks.count
        return count > 0 ? "\(count)" : nil
    }

    private var hasActiveDownloads: Bool {
        appState.libraryStore.activeDownloads.values.contains {
            $0.status == .downloading || $0.status == .queued
        }
    }

    private var downloadsBadgeText: String? {
        let active = appState.libraryStore.activeDownloads.values.filter {
            $0.status == .downloading || $0.status == .queued
        }.count
        if active > 0 { return "\(active) active" }
        let total = appState.libraryStore.downloads.count
        return total > 0 ? "\(total)" : nil
    }

    private var localBadgeText: String? {
        let count = appState.libraryStore.localTracks.count
        return count > 0 ? "\(count)" : nil
    }

    private var enabledAddonsCount: Int {
        appState.addonManager.addons.filter(\.isEnabled).count
    }

    private var addonsBadgeText: String? {
        enabledAddonsCount > 0 ? "\(enabledAddonsCount)" : nil
    }

    private var discordIndicatorColor: Color {
        if !appState.libraryStore.settings.discordRPCEnabled {
            return secondaryText.opacity(0.45)
        }
        return appState.isDiscordConnected ? Color(red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0) : .orange
    }

    private var discordLabel: String {
        if !appState.libraryStore.settings.discordRPCEnabled {
            return "Discord Off"
        }
        return appState.isDiscordConnected ? "Discord Live" : "Discord Idle"
    }
}

// MARK: - Hoverable Sidebar Row Button

private struct SidebarNavButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let badge: String?
    let isActiveBadge: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? accent : secondary)
                    .frame(width: 20, alignment: .center)

                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActiveBadge ? accentFg : secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isActiveBadge ? accent : Color.primary.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return colorScheme == .dark
                ? SoundChordTheme.darkSurfaceHover
                : Color.black.opacity(0.08)
        }
        if isHovered {
            return colorScheme == .dark
                ? SoundChordTheme.darkSurface
                : Color.black.opacity(0.04)
        }
        return .clear
    }
}
