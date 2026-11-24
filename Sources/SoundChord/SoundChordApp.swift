import AppKit
import MediaPlayer
import QuartzCore
import SwiftUI

// MARK: - High-Refresh Display Pacer (60Hz-300Hz ProMotion / Adaptive Refresh)

@MainActor
final class HighRefreshDisplayPacer {
    private final class DisplayLinkProxy: NSObject {
        weak var owner: HighRefreshDisplayPacer?

        init(owner: HighRefreshDisplayPacer) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            // Keeps CoreAnimation high-refresh pacing engaged during active playback.
            _ = link
        }
    }

    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var isPlaying: Bool = false
    private var activeMaxFPS: Int = 0
    private var observers: [NSObjectProtocol] = []

    init() {}

    deinit {
        displayLink?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func attach(to newWindow: NSWindow?) {
        if window === newWindow {
            configureWindowLayerIfNeeded()
            updateState()
            return
        }

        tearDownObservers()
        stopDisplayLink()
        window = newWindow

        guard let newWindow else { return }
        configureWindowLayerIfNeeded()
        installObservers(for: newWindow)
        updateState()
    }

    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        updateState()
    }

    func stop() {
        tearDownObservers()
        stopDisplayLink()
        window = nil
    }

    private func configureWindowLayerIfNeeded() {
        guard let contentView = window?.contentView else { return }
        if !contentView.wantsLayer {
            contentView.wantsLayer = true
        }
    }

    private func installObservers(for targetWindow: NSWindow) {
        let nc = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]

        for name in windowNotifications {
            let token = nc.addObserver(forName: name, object: targetWindow, queue: .main) { [weak self] notification in
                let isClosing = notification.name == NSWindow.willCloseNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if isClosing {
                        self.stop()
                    } else {
                        self.updateState(forceRefreshRateSync: notification.name == NSWindow.didChangeScreenNotification)
                    }
                }
            }
            observers.append(token)
        }

        let appNotifications: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in appNotifications {
            let token = nc.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateState()
                }
            }
            observers.append(token)
        }

        let accessibilityToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateState()
            }
        }
        observers.append(accessibilityToken)
    }

    private func tearDownObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private var shouldRunDisplayLink: Bool {
        guard isPlaying,
              let window,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              !NSApp.isHidden,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return false
        }
        return true
    }

    private static func targetMaxFPS(for screen: NSScreen?) -> Int {
        let raw = screen?.maximumFramesPerSecond ?? 60
        return min(300, max(60, raw))
    }

    private func updateState(forceRefreshRateSync: Bool = false) {
        guard shouldRunDisplayLink, let window else {
            stopDisplayLink()
            return
        }

        let maxFPS = Self.targetMaxFPS(for: window.screen ?? NSScreen.main)
        if let existing = displayLink {
            if forceRefreshRateSync || activeMaxFPS != maxFPS {
                existing.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: Float(maxFPS),
                    preferred: Float(maxFPS)
                )
                activeMaxFPS = maxFPS
            }
            if existing.isPaused {
                existing.isPaused = false
            }
            return
        }

        let linkProxy = DisplayLinkProxy(owner: self)
        let link = window.displayLink(target: linkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: Float(maxFPS),
            preferred: Float(maxFPS)
        )
        link.add(to: .main, forMode: .common)
        proxy = linkProxy
        displayLink = link
        activeMaxFPS = maxFPS
    }

    private func stopDisplayLink() {
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        activeMaxFPS = 0
    }
}

private struct WindowPerformanceBridge: NSViewRepresentable {
    let isPlaying: Bool

    final class HostingObserverView: NSView {
        let pacer = HighRefreshDisplayPacer()
        var pendingIsPlaying: Bool = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.contentView?.wantsLayer = true
            }
            pacer.setPlaying(pendingIsPlaying)
            pacer.attach(to: window)
        }
    }

    func makeNSView(context: Context) -> HostingObserverView {
        let view = HostingObserverView(frame: .zero)
        view.pendingIsPlaying = isPlaying
        return view
    }

    func updateNSView(_ nsView: HostingObserverView, context: Context) {
        nsView.pendingIsPlaying = isPlaying
        nsView.pacer.setPlaying(isPlaying)
        if let window = nsView.window {
            if window.contentView?.wantsLayer == false {
                window.contentView?.wantsLayer = true
            }
            nsView.pacer.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: HostingObserverView, coordinator: ()) {
        nsView.pacer.stop()
    }
}

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
            window.contentView?.wantsLayer = true
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
                .background(
                    WindowPerformanceBridge(isPlaying: appState.audioEngine.isPlaying)
                        .allowsHitTesting(false)
                )
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
