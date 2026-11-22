import AppKit
import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var keyMonitor: Any?

    public init() {}

    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        ZStack {
            if isDark {
                darkSpotifyShell
            } else {
                lightAppleMusicShell
            }

            // Full-screen Now Playing modal overlay
            if appState.showFullScreenPlayer {
                FullScreenPlayerView()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 0.98))
                        )
                    )
                    .zIndex(50)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: appState.showFullScreenPlayer)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appState.showRightDrawer)
        .sheet(isPresented: $appState.showImportPlaylistSheet) {
            ImportPlaylistSheet()
                .environmentObject(appState)
        }
        .onAppear {
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - Light Mode Shell (Apple Music)

    private var lightAppleMusicShell: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                SidebarView()

                Rectangle()
                    .fill(SoundChordTheme.hairline(for: .light))
                    .frame(width: 1)
                    .ignoresSafeArea()

                mainStage
                    .background(SoundChordTheme.panelBackground(for: .light))

                if appState.showRightDrawer {
                    RightDrawerView()
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(SoundChordTheme.windowBackground(for: .light).ignoresSafeArea())

            // Floating toast capsule just above the floating player bar
            if let toast = appState.toastMessage {
                toastView(message: toast)
                    .padding(.bottom, 88)
                    .padding(.leading, 20)
                    .padding(.trailing, appState.showRightDrawer ? 320 : 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(25)
                    .allowsHitTesting(false)
            }

            // Floating bottom Apple Music Liquid Glass pill player (Glass #2 and FINAL glass surface)
            FloatingPlayerBar()
                .padding(.bottom, 18)
                .padding(.leading, 20)
                .padding(.trailing, appState.showRightDrawer ? 320 : 20)
                .zIndex(15)
        }
        .animation(.easeInOut(duration: 0.22), value: appState.toastMessage)
        .animation(.easeInOut(duration: 0.22), value: appState.errorBanner)
    }

    // MARK: - Dark Mode Shell (Spotify)

    private var darkSpotifyShell: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SidebarView()
                    .background(SoundChordTheme.panelBackground(for: .dark))
                    .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusPanel, style: .continuous))

                ZStack(alignment: .bottom) {
                    mainStage
                        .background(SoundChordTheme.panelBackground(for: .dark))
                        .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusPanel, style: .continuous))

                    if let toast = appState.toastMessage {
                        toastView(message: toast)
                            .padding(.bottom, 16)
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(25)
                            .allowsHitTesting(false)
                    }
                }

                if appState.showRightDrawer {
                    RightDrawerView()
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .background(SoundChordTheme.panelBackground(for: .dark))
                        .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusPanel, style: .continuous))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            // Docked full-width solid #000000 bottom player bar (ZERO glass blur in Dark Mode)
            FloatingPlayerBar()
        }
        .background(SoundChordTheme.windowBackground(for: .dark).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.22), value: appState.toastMessage)
        .animation(.easeInOut(duration: 0.22), value: appState.errorBanner)
    }

    // MARK: - Main Stage

    private var mainStage: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $appState.navigationPath) {
                rootDestinationView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SoundChordTheme.panelBackground(for: colorScheme))
                    .navigationDestination(for: NavigationDestination.self) { destination in
                        destinationView(for: destination)
                            .background(SoundChordTheme.panelBackground(for: colorScheme))
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage = appState.errorBanner {
                errorBannerView(message: errorMessage)
                    .padding(.top, 14)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
            }
        }
    }

    // MARK: - Sidebar & Destination Routing

    @ViewBuilder
    private var rootDestinationView: some View {
        switch appState.selectedSidebar {
        case .home:
            HomeView()
        case .explore:
            ExploreView()
        case .search:
            SearchView()
        case .library:
            LibraryView()
        case .downloads:
            DownloadsView()
        case .localMusic:
            LocalMusicView()
        case .replay:
            ReplayView()
        case .addons:
            AddonsView(addonManager: appState.addonManager)
        case .settings:
            SettingsView()
        case .playlist(let id):
            PlaylistDetailView(playlistId: id)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        switch destination {
        case .album(let album):
            AlbumDetailView(albumId: album.id, initialAlbum: album)
        case .albumId(let id):
            AlbumDetailView(albumId: id)
        case .artist(let artist):
            ArtistDetailView(artistId: artist.id, initialArtist: artist)
        case .artistId(let id):
            ArtistDetailView(artistId: id)
        case .playlist(let playlist):
            PlaylistDetailView(playlistId: playlist.id, initialPlaylist: playlist)
        case .playlistId(let id):
            PlaylistDetailView(playlistId: id)
        case .shelf(let shelf):
            ShelfDetailView(shelf: shelf)
        }
    }

    // MARK: - Overlays

    private func errorBannerView(message: String) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let bg = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accent)

            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button {
                appState.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.12), radius: 12, y: 4)
    }

    private func toastView(message: String) -> some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let bg = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(bg))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.12), radius: 10, y: 4)
    }

    // MARK: - Global Non-Conflicting Keyboard Monitor (Space & Escape)

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape: close Full-Screen Player, Import sheet, or Stats for Nerds popover
            if event.keyCode == 53 {
                if appState.showStatsForNerds {
                    Task { @MainActor in
                        appState.showStatsForNerds = false
                    }
                    return nil
                }
                if appState.showImportPlaylistSheet {
                    Task { @MainActor in
                        appState.showImportPlaylistSheet = false
                    }
                    return nil
                }
                if appState.showFullScreenPlayer {
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            appState.showFullScreenPlayer = false
                        }
                    }
                    return nil
                }
                return event
            }

            // Unmodified Space: Play / Pause only when not typing in a text field
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 49 && flags.isEmpty {
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSText || responder is NSTextView {
                    return event
                }
                if appState.audioEngine.currentTrack != nil {
                    Task { @MainActor in
                        appState.audioEngine.togglePlayPause()
                    }
                    return nil
                }
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
