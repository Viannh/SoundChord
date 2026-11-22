import AppKit
import Foundation

// MARK: - AppleScript / JXA Scripting Bridge

/// Connects macOS Cocoa Scripting (AppleScript & JXA via `SoundChord.sdef`) to `AudioEngine`.
/// Allows external macOS controllers such as Raycast and Shortcuts to inspect
/// now-playing metadata and control playback over Apple Events.
@MainActor
public final class AppleScriptBridge {
    public static let shared = AppleScriptBridge()

    private weak var audioEngine: AudioEngine?

    private init() {}

    public func attach(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    public var engine: AudioEngine? {
        audioEngine
    }

    // FourCharCode constants matching SoundChord.sdef `EPlS` enumeration
    public static let stateStopped: FourCharCode = fourCharCode("kPSS")
    public static let statePlaying: FourCharCode = fourCharCode("kPSP")
    public static let statePaused: FourCharCode = fourCharCode("kPSp")

    public static func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    public func currentPlayerStateCode() -> FourCharCode {
        guard let engine = audioEngine, engine.currentTrack != nil else {
            return Self.stateStopped
        }
        return engine.isPlaying ? Self.statePlaying : Self.statePaused
    }

    public func makeCurrentScriptableTrack() -> SoundChordScriptableTrack? {
        guard let engine = audioEngine, let track = engine.currentTrack else {
            return nil
        }
        let effectiveDuration = engine.duration > 0 ? engine.duration : track.duration
        return SoundChordScriptableTrack(track: track, durationSeconds: effectiveDuration)
    }

    public func setRepeating(_ enabled: Bool) {
        guard let engine = audioEngine else { return }
        if enabled {
            if engine.repeatMode == .off {
                engine.cycleRepeatMode()
            }
        } else {
            var guardCount = 0
            while engine.repeatMode != .off && guardCount < 4 {
                engine.cycleRepeatMode()
                guardCount += 1
            }
        }
    }
}

// MARK: - Scriptable Track Object

@objc(SoundChordScriptableTrack)
public final class SoundChordScriptableTrack: NSObject {
    @objc public let scriptTrackID: String
    @objc public let scriptTitle: String
    @objc public let scriptArtist: String
    @objc public let scriptAlbum: String
    @objc public let scriptDurationMs: Int
    @objc public let scriptArtworkURL: String

    public init(track: Track, durationSeconds: TimeInterval) {
        self.scriptTrackID = track.id
        self.scriptTitle = track.title
        self.scriptArtist = track.artist
        self.scriptAlbum = track.album ?? ""
        let clampedSeconds = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0
        self.scriptDurationMs = Int((clampedSeconds * 1000.0).rounded())

        if let url = track.highResArtworkURL ?? track.artworkURL,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            self.scriptArtworkURL = url.absoluteString
        } else {
            self.scriptArtworkURL = ""
        }
        super.init()
    }

    public override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSPropertySpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "currentTrack"
        )
    }
}

// MARK: - NSApplication KVC Scripting Properties

extension NSApplication {
    @objc var currentTrack: SoundChordScriptableTrack? {
        MainActor.assumeIsolated {
            AppleScriptBridge.shared.makeCurrentScriptableTrack()
        }
    }

    @objc var playerState: NSNumber {
        MainActor.assumeIsolated {
            NSNumber(value: AppleScriptBridge.shared.currentPlayerStateCode())
        }
    }

    @objc var playerPosition: Double {
        get {
            MainActor.assumeIsolated {
                AppleScriptBridge.shared.engine?.currentTime ?? 0
            }
        }
        set {
            MainActor.assumeIsolated {
                AppleScriptBridge.shared.engine?.seek(to: max(0, newValue))
            }
        }
    }

    @objc var shuffling: Bool {
        get {
            MainActor.assumeIsolated {
                AppleScriptBridge.shared.engine?.isShuffled ?? false
            }
        }
        set {
            MainActor.assumeIsolated {
                guard let engine = AppleScriptBridge.shared.engine else { return }
                if engine.isShuffled != newValue {
                    engine.toggleShuffle()
                }
            }
        }
    }

    @objc var shufflingEnabled: Bool {
        true
    }

    @objc var repeating: Bool {
        get {
            MainActor.assumeIsolated {
                guard let engine = AppleScriptBridge.shared.engine else { return false }
                return engine.repeatMode != .off
            }
        }
        set {
            MainActor.assumeIsolated {
                AppleScriptBridge.shared.setRepeating(newValue)
            }
        }
    }

    @objc var repeatingEnabled: Bool {
        true
    }

    @objc var soundVolume: Int {
        get {
            MainActor.assumeIsolated {
                guard let engine = AppleScriptBridge.shared.engine else { return 0 }
                return Int((engine.volume * 100.0).rounded())
            }
        }
        set {
            MainActor.assumeIsolated {
                let clamped = max(0, min(100, newValue))
                AppleScriptBridge.shared.engine?.setVolume(Float(clamped) / 100.0)
            }
        }
    }
}

// MARK: - AppleScript Command Handlers

@objc(SoundChordPlayPauseCommand)
final class SoundChordPlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AppleScriptBridge.shared.engine?.togglePlayPause()
        }
        return nil
    }
}

@objc(SoundChordPlayCommand)
final class SoundChordPlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AppleScriptBridge.shared.engine?.resume()
        }
        return nil
    }
}

@objc(SoundChordPauseCommand)
final class SoundChordPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AppleScriptBridge.shared.engine?.pause()
        }
        return nil
    }
}

@objc(SoundChordNextTrackCommand)
final class SoundChordNextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let engine = AppleScriptBridge.shared.engine else { return }
            Task { await engine.next() }
        }
        return nil
    }
}

@objc(SoundChordPreviousTrackCommand)
final class SoundChordPreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let engine = AppleScriptBridge.shared.engine else { return }
            Task { await engine.previous() }
        }
        return nil
    }
}
