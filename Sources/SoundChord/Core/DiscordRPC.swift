import Darwin
import Foundation

// MARK: - Discord Rich Presence (Native macOS Unix Domain Socket IPC)

public final class DiscordRPC: DiscordRPCProtocol, @unchecked Sendable {
    /// Official BitChord Discord Application ID.
    public static let defaultClientId = "1543679166967193620"

    private let connection: DiscordIPCConnection

    public init(clientId: String = DiscordRPC.defaultClientId) {
        self.connection = DiscordIPCConnection(clientId: clientId)
    }

    public var isConnected: Bool {
        get async {
            await connection.isConnected
        }
    }

    public func connect() async {
        await connection.connect(force: true)
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    public func updatePresence(
        track: Track,
        stream: ResolvedStream?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        settings: AppSettings
    ) async {
        guard settings.discordRPCEnabled else {
            await connection.clearPresence()
            return
        }

        if !isPlaying {
            await connection.clearPresence()
            return
        }

        await connection.setListeningActivity(
            track: track,
            stream: stream,
            elapsed: elapsed,
            duration: duration,
            showButtons: settings.discordShowButtons
        )
    }

    public func clearPresence() async {
        await connection.clearPresence()
    }

    // MARK: - Internal Testing Seams

    internal func attachConnectedSocketForTesting(_ fd: Int32) async {
        await connection.attachConnectedSocket(fd)
    }

    internal static func encodeFrame(opcode: UInt32, jsonObject: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: jsonObject, options: []) else {
            return nil
        }
        var frame = Data(capacity: 8 + body.count)
        var opLE = opcode.littleEndian
        var lenLE = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &opLE) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLE) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    internal static func decodeFrame(from data: Data) -> (opcode: UInt32, payload: Data)? {
        guard data.count >= 8 else { return nil }
        let rawOp: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let rawLen: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian
        let totalExpected = 8 + Int(rawLen)
        guard rawLen <= 1_048_576, data.count >= totalExpected else { return nil }
        let payload = data.subdata(in: 8..<totalExpected)
        return (rawOp, payload)
    }
}

// MARK: - Internal IPC Actor

private actor DiscordIPCConnection {
    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    private static let textLimit = 128
    private static let buttonLabelLimit = 32
    private static let reconnectCooldownSeconds: TimeInterval = 15.0

    private let clientId: String
    private var socketFD: Int32 = -1
    private var connected: Bool = false
    private var lastConnectAttempt: Date = .distantPast
    private var lastSentFingerprint: String?

    init(clientId: String) {
        self.clientId = clientId
    }

    deinit {
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    var isConnected: Bool {
        connected && socketFD >= 0
    }

    func connect(force: Bool = false) {
        if isConnected { return }

        let now = Date()
        if !force && now.timeIntervalSince(lastConnectAttempt) < Self.reconnectCooldownSeconds {
            return
        }
        lastConnectAttempt = now

        closeSocketLocked()

        for path in Self.candidateSocketPaths() {
            guard let fd = Self.openUnixSocket(path: path) else { continue }
            if performHandshake(on: fd) {
                return
            }
        }

        connected = false
    }

    func attachConnectedSocket(_ fd: Int32) {
        closeSocketLocked()
        guard fd >= 0 else { return }
        Self.configureSocketOptions(fd)
        _ = performHandshake(on: fd)
    }

    private func performHandshake(on fd: Int32) -> Bool {
        socketFD = fd
        let handshake: [String: Any] = [
            "v": 1,
            "client_id": clientId
        ]
        guard sendFrame(opcode: .handshake, jsonObject: handshake) else {
            closeSocketLocked()
            return false
        }

        // Read handshake response (READY event)
        if let response = readFrame(), response.opcode == .frame {
            connected = true
            lastSentFingerprint = nil
            return true
        }

        closeSocketLocked()
        return false
    }

    func disconnect() {
        if isConnected {
            _ = sendFrame(opcode: .close, jsonObject: [:])
        }
        closeSocketLocked()
        lastSentFingerprint = nil
    }

    func clearPresence() {
        guard isConnected else { return }
        if lastSentFingerprint == "__CLEARED__" { return }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "activity": NSNull()
            ],
            "nonce": UUID().uuidString
        ]

        if sendFrame(opcode: .frame, jsonObject: payload) {
            _ = drainAvailableResponse()
            lastSentFingerprint = "__CLEARED__"
        } else {
            closeSocketLocked()
        }
    }

    func setListeningActivity(
        track: Track,
        stream: ResolvedStream?,
        elapsed: TimeInterval,
        duration: TimeInterval,
        showButtons: Bool
    ) {
        if !isConnected {
            connect(force: false)
        }
        guard isConnected else { return }

        let details = Self.clampDiscordText(track.title, fallback: "Unknown Track")
        let state = Self.clampDiscordText(track.artist, fallback: "Unknown Artist")
        let qualityLine = Self.buildQualityOrAlbumLine(track: track, stream: stream)

        let now = Date().timeIntervalSince1970
        let safeElapsed = max(0, elapsed.isFinite ? elapsed : 0)
        let startEpoch = Int64((now - safeElapsed).rounded())
        var timestamps: [String: Any] = ["start": startEpoch]
        let effectiveDuration = duration.isFinite && duration > 0 ? duration : track.duration
        if effectiveDuration > 0 && effectiveDuration.isFinite {
            let remaining = max(0, effectiveDuration - safeElapsed)
            timestamps["end"] = Int64((now + remaining).rounded())
        }

        var assets: [String: Any] = [
            "large_text": Self.clampDiscordText(qualityLine, fallback: "SoundChord")
        ]
        if let artURL = track.highResArtworkURL ?? track.artworkURL,
           let scheme = artURL.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            assets["large_image"] = artURL.absoluteString
        }

        var activity: [String: Any] = [
            "type": 2, // Listening
            "details": details,
            "state": state,
            "timestamps": timestamps,
            "assets": assets
        ]

        if showButtons && !track.isLocal && !track.videoId.isEmpty {
            let ytURL = "https://music.youtube.com/watch?v=\(track.videoId)"
            let buttons: [[String: String]] = [
                [
                    "label": String("Listen on YouTube Music".prefix(Self.buttonLabelLimit)),
                    "url": ytURL
                ]
            ]
            activity["buttons"] = buttons
        }

        // Deduplicate rapid updates within the same second for identical track state
        let bucketStart = startEpoch / 3
        let fingerprint = "\(track.id)|\(details)|\(state)|\(qualityLine)|\(bucketStart)|\(showButtons)"
        if fingerprint == lastSentFingerprint {
            return
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "activity": activity
            ],
            "nonce": UUID().uuidString
        ]

        if sendFrame(opcode: .frame, jsonObject: payload) {
            _ = drainAvailableResponse()
            lastSentFingerprint = fingerprint
        } else {
            closeSocketLocked()
        }
    }

    // MARK: - Framing & Socket I/O

    private func sendFrame(opcode: Opcode, jsonObject: [String: Any]) -> Bool {
        guard socketFD >= 0 else { return false }
        guard let frame = DiscordRPC.encodeFrame(opcode: opcode.rawValue, jsonObject: jsonObject) else {
            return false
        }
        return writeAll(data: frame)
    }

    private func writeAll(data: Data) -> Bool {
        guard socketFD >= 0 else { return false }
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(socketFD, base.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 {
                    if sent < 0 && errno == EINTR { continue }
                    return false
                }
                totalSent += sent
            }
            return true
        }
    }

    private func readFrame() -> (opcode: Opcode, payload: Data)? {
        guard socketFD >= 0 else { return nil }
        guard let header = readExact(count: 8) else { return nil }

        let rawOp: UInt32 = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let rawLen: UInt32 = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian

        // Sanity cap at 1 MB to protect against malformed frames
        guard rawLen <= 1_048_576 else { return nil }
        let body: Data
        if rawLen > 0 {
            guard let payload = readExact(count: Int(rawLen)) else { return nil }
            body = payload
        } else {
            body = Data()
        }

        guard let opcode = Opcode(rawValue: rawOp) else {
            return nil
        }

        if opcode == .ping {
            // Reply with pong carrying the same payload
            var pong = Data(capacity: 8 + body.count)
            var opLE = Opcode.pong.rawValue.littleEndian
            var lenLE = UInt32(body.count).littleEndian
            withUnsafeBytes(of: &opLE) { pong.append(contentsOf: $0) }
            withUnsafeBytes(of: &lenLE) { pong.append(contentsOf: $0) }
            pong.append(body)
            _ = writeAll(data: pong)
            return readFrame()
        }

        if opcode == .close {
            closeSocketLocked()
            return nil
        }

        return (opcode, body)
    }

    private func drainAvailableResponse() -> Bool {
        guard socketFD >= 0 else { return false }
        var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        // Non-blocking / 150ms poll so we consume Discord's reply without stalling
        let ready = Darwin.poll(&pfd, 1, 150)
        if ready > 0 {
            if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                closeSocketLocked()
                return false
            }
            if (pfd.revents & Int16(POLLIN)) != 0 {
                return readFrame() != nil
            }
        }
        return true
    }

    private func readExact(count: Int) -> Data? {
        guard socketFD >= 0, count > 0 else { return Data() }
        var buffer = Data(count: count)
        var totalRead = 0
        let ok = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            while totalRead < count {
                let n = Darwin.recv(socketFD, base.advanced(by: totalRead), count - totalRead, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                totalRead += n
            }
            return true
        }
        return ok ? buffer : nil
    }

    private func closeSocketLocked() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connected = false
    }

    // MARK: - Socket Discovery & Helpers

    private static func candidateSocketPaths() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var dirs: [String] = []
        let candidates = [
            env["XDG_RUNTIME_DIR"],
            env["TMPDIR"],
            env["TMP"],
            env["TEMP"],
            NSTemporaryDirectory(),
            "/tmp"
        ]
        var seen = Set<String>()
        for raw in candidates.compactMap({ $0 }) {
            let trimmed = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            dirs.append(trimmed)
        }

        var paths: [String] = []
        for dir in dirs {
            for index in 0...9 {
                let path = "\(dir)/discord-ipc-\(index)"
                if FileManager.default.fileExists(atPath: path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    private static func configureSocketOptions(_ fd: Int32) {
        // Prevent SIGPIPE when Discord disconnects
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Short send/receive timeouts so IPC never blocks background threads
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func openUnixSocket(path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configureSocketOptions(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            Darwin.close(fd)
            return nil
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = path.withCString { src in
                    strncpy(dest, src, maxLen - 1)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        if result != 0 {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private static func clampDiscordText(_ raw: String, fallback: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? fallback : cleaned
        if base.count == 1 {
            // Discord rejects activity text fields shorter than 2 characters
            return base + "\u{200B}"
        }
        if base.count > textLimit {
            return String(base.prefix(textLimit - 1)) + "…"
        }
        return base
    }

    private static func buildQualityOrAlbumLine(track: Track, stream: ResolvedStream?) -> String {
        var parts: [String] = []
        if let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            parts.append(album)
        }
        if let stream {
            let quality = stream.formattedSummary
            if !quality.isEmpty {
                parts.append(quality)
            }
        } else if let quality = track.qualityLabel, !quality.isEmpty {
            parts.append(quality)
        }
        if parts.isEmpty {
            return "SoundChord for macOS"
        }
        return parts.joined(separator: " · ")
    }
}
