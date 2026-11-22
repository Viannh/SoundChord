import AppKit
import MediaPlayer
import SwiftUI

// MARK: - AppKit Delegate

final class SoundChordAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        configureMainWindows()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureMainWindows() {
        for window in NSApp.windows {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

// MARK: - Main App Entry Point

@main
public struct SoundChordApp: App {
    @NSApplicationDelegateAdaptor(SoundChordAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup("SoundChord") {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    AppleScriptBridge.shared.attach(audioEngine: appState.audioEngine)
                    await appState.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            playbackCommands
            viewCommands
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appState.libraryStore.settings.themeMode {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    // MARK: - Native MenuBar Commands

    @CommandsBuilder
    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            Button(appState.audioEngine.isPlaying ? "Pause" : "Play") {
                appState.audioEngine.togglePlayPause()
            }
            .disabled(appState.audioEngine.currentTrack == nil)

            Button("Next Track") {
                Task { await appState.audioEngine.next() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(appState.audioEngine.currentTrack == nil)

            Button("Previous Track") {
                Task { await appState.audioEngine.previous() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(appState.audioEngine.currentTrack == nil)

            Divider()

            Button("Volume Up") {
                let next = min(1.0, appState.audioEngine.volume + 0.08)
                appState.audioEngine.setVolume(next)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Volume Down") {
                let next = max(0.0, appState.audioEngine.volume - 0.08)
                appState.audioEngine.setVolume(next)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button(appState.audioEngine.isMuted ? "Unmute" : "Mute") {
                appState.audioEngine.toggleMute()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])

            Divider()

            Button(appState.audioEngine.isShuffled ? "Disable Shuffle" : "Enable Shuffle") {
                appState.audioEngine.toggleShuffle()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Cycle Repeat (\(appState.audioEngine.repeatMode.displayName))") {
                appState.audioEngine.cycleRepeatMode()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandMenu("View") {
            Button("Search") {
                if appState.showFullScreenPlayer {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.showFullScreenPlayer = false
                    }
                }
                appState.selectSidebar(.search)
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button(
                appState.showRightDrawer && appState.rightDrawerTab == .lyrics
                    ? "Hide Lyrics"
                    : "Show Lyrics"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .lyrics)
                }
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(
                appState.showRightDrawer && appState.rightDrawerTab == .queue
                    ? "Hide Up Next"
                    : "Show Up Next"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .queue)
                }
            }
            .keyboardShortcut("u", modifiers: .command)

            Button("Toggle Chords") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    appState.toggleRightDrawer(tab: .chords)
                }
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button(appState.showFullScreenPlayer ? "Exit Full-Screen Player" : "Full-Screen Player") {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                    appState.showFullScreenPlayer.toggle()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(appState.audioEngine.currentTrack == nil && !appState.showFullScreenPlayer)

            Button("Stats for Nerds") {
                appState.showStatsForNerds.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}
