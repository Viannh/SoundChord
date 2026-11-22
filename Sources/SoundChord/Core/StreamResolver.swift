import Foundation
import JavaScriptCore

// MARK: - Stream Resolver (Multi-Client YouTube /player + JavaScriptCore Decipher)

public final class StreamResolver: StreamResolverProtocol, Sendable {
    private static let visitorDataDefaultsKey = "BitChord.InnerTube.visitorData"
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    private let session: URLSession
    private let cache: ResolverState
    private let skipMediaProbe: Bool

    private static let authBoundaryBytes: Int64 = 1_048_576 // 1 MiB YouTube CDN auth boundary
    private static let probeWindowBytes: Int64 = 65_536     // 64 KiB read verification

    // MARK: - Client Profiles (Ordered Fallback Chain)

    private struct ClientProfile: Sendable {
        let name: String
        let clientName: String
        let clientVersion: String
        let clientId: String
        let endpoint: String
        let userAgent: String
        let origin: String?
        let referer: String?
        let deviceMake: String?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?
        let androidSdkVersion: Int?
        let platform: String?
        let embedURL: String?
        let supportsCipherFallback: Bool
        let sendMediaHeaders: Bool
        let requiresCookie: Bool

        var playbackHeaders: [String: String] {
            guard sendMediaHeaders else { return [:] }
            var headers: [String: String] = ["User-Agent": userAgent]
            if let origin { headers["Origin"] = origin }
            if let referer { headers["Referer"] = referer }
            return headers
        }
    }

    private static let clientProfiles: [ClientProfile] = [
        ClientProfile(
            name: "VISIONOS_0_1",
            clientName: "VISIONOS",
            clientVersion: "0.1",
            clientId: "101",
            endpoint: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: "com.google.visionos.youtube/0.1 (RealityDevice14,1; U; CPU visionOS 1_0 like Mac OS X; en_US)",
            origin: nil,
            referer: nil,
            deviceMake: "Apple",
            deviceModel: "RealityDevice14,1",
            osName: "VISION_OS",
            osVersion: "1.0",
            androidSdkVersion: nil,
            platform: "MOBILE",
            embedURL: nil,
            supportsCipherFallback: false,
            sendMediaHeaders: false,
            requiresCookie: false
        ),
        ClientProfile(
            name: "VISIONOS_1_02",
            clientName: "VISIONOS",
            clientVersion: "1.02",
            clientId: "101",
            endpoint: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: "com.google.visionos.youtube/1.02 (RealityDevice14,1; U; CPU visionOS 1_0 like Mac OS X; en_US)",
            origin: nil,
            referer: nil,
            deviceMake: "Apple",
            deviceModel: "RealityDevice14,1",
            osName: "VISION_OS",
            osVersion: "1.0",
            androidSdkVersion: nil,
            platform: nil,
            embedURL: nil,
            supportsCipherFallback: false,
            sendMediaHeaders: false,
            requiresCookie: false
        ),
        ClientProfile(
            name: "IOS",
            clientName: "IOS",
            clientVersion: "21.29.1",
            clientId: "5",
            endpoint: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: "com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)",
            origin: nil,
            referer: nil,
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.5.0.22F76",
            androidSdkVersion: nil,
            platform: nil,
            embedURL: nil,
            supportsCipherFallback: false,
            sendMediaHeaders: true,
            requiresCookie: false
        ),
        ClientProfile(
            name: "ANDROID_VR",
            clientName: "ANDROID_VR",
            clientVersion: "1.65.10",
            clientId: "28",
            endpoint: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            origin: nil,
            referer: nil,
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12L",
            androidSdkVersion: 32,
            platform: nil,
            embedURL: nil,
            supportsCipherFallback: false,
            sendMediaHeaders: true,
            requiresCookie: false
        ),
        ClientProfile(
            name: "WEB_REMIX",
            clientName: "WEB_REMIX",
            clientVersion: "1.20260707.12.00",
            clientId: "67",
            endpoint: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: webUserAgent,
            origin: "https://music.youtube.com",
            referer: "https://music.youtube.com/",
            deviceMake: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil,
            androidSdkVersion: nil,
            platform: nil,
            embedURL: nil,
            supportsCipherFallback: true,
            sendMediaHeaders: true,
            requiresCookie: true
        )
    ]

    // MARK: - Thread-Safe Cache & Player JS State

    private struct CachedPlayerJS: Sendable {
        let scriptURL: String
        let signatureTimestamp: Int?
        let jsSource: String
        let fetchedAt: Date
    }

    private actor ResolverState {
        var streams: [String: ResolvedStream] = [:]
        var inFlight: [String: Task<ResolvedStream, Error>] = [:]
        var visitorData: String?
        var cookie: String?
        var playerJS: CachedPlayerJS?

        init() {
            if let stored = UserDefaults.standard.string(forKey: StreamResolver.visitorDataDefaultsKey),
               !stored.isEmpty {
                self.visitorData = stored
            }
        }

        func validStream(for key: String) -> ResolvedStream? {
            guard let cached = streams[key] else { return nil }
            if cached.isExpired {
                streams.removeValue(forKey: key)
                return nil
            }
            return cached
        }

        func storeStream(_ stream: ResolvedStream, for key: String) {
            if streams.count >= 200 {
                // Evict expired first, then oldest half if still full.
                streams = streams.filter { !$0.value.isExpired }
                if streams.count >= 200 {
                    streams.removeAll(keepingCapacity: true)
                }
            }
            streams[key] = stream
        }

        func invalidate(videoId: String) {
            let prefix = "\(videoId)::"
            streams = streams.filter { !$0.key.hasPrefix(prefix) }
        }

        func existingTask(for key: String) -> Task<ResolvedStream, Error>? {
            inFlight[key]
        }

        func setTask(_ task: Task<ResolvedStream, Error>?, for key: String) {
            inFlight[key] = task
        }

        func getVisitorData() -> String? {
            if let visitorData, !visitorData.isEmpty { return visitorData }
            if let stored = UserDefaults.standard.string(forKey: StreamResolver.visitorDataDefaultsKey),
               !stored.isEmpty {
                self.visitorData = stored
                return stored
            }
            return nil
        }

        func setVisitorData(_ value: String) {
            self.visitorData = value
            UserDefaults.standard.set(value, forKey: StreamResolver.visitorDataDefaultsKey)
        }

        func clearVisitorData() {
            self.visitorData = nil
            UserDefaults.standard.removeObject(forKey: StreamResolver.visitorDataDefaultsKey)
        }

        func getCookie() -> String? {
            cookie
        }

        func setCookie(_ newCookie: String?) {
            let trimmed = newCookie?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.cookie = (trimmed?.isEmpty == false) ? trimmed : nil
        }

        func getPlayerJS() -> CachedPlayerJS? {
            guard let playerJS else { return nil }
            if Date().timeIntervalSince(playerJS.fetchedAt) > 3600 * 6 {
                self.playerJS = nil
                return nil
            }
            return playerJS
        }

        func setPlayerJS(_ value: CachedPlayerJS) {
            self.playerJS = value
        }

        func clearAll() {
            streams.removeAll()
            playerJS = nil
        }
    }

    // MARK: - Init

    public convenience init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.init(session: URLSession(configuration: config), skipMediaProbe: false)
    }

    internal init(session: URLSession, skipMediaProbe: Bool = true) {
        self.session = session
        self.cache = ResolverState()
        self.skipMediaProbe = skipMediaProbe
    }

    // MARK: - StreamResolverProtocol

    public func setCookie(_ cookie: String?) async {
        await cache.setCookie(cookie)
    }

    public func invalidate(videoId: String) async {
        let trimmedId = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        await cache.invalidate(videoId: trimmedId)
    }

    public func clearCache() async {
        await cache.clearAll()
    }

    private enum CandidateSelectionMode: Sendable {
        case playback(AudioQuality)
        case compactAnalysis
    }

    public func resolveStream(videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        try await resolveWithCache(
            videoId: videoId,
            cacheKeySuffix: quality.rawValue,
            profiles: Self.clientProfiles,
            mode: .playback(quality)
        )
    }

    /// Resolves a lightweight progressive audio/mp4 stream (`itag 139` 48 kbps preferred, `itag 140` fallback)
    /// using the `VISIONOS_0_1` -> `VISIONOS_1_02` clients for fast two-pass chord analysis.
    public func resolveCompactAudioForAnalysis(videoId: String) async throws -> ResolvedStream {
        let visionOSProfiles = Self.clientProfiles.filter { $0.clientName == "VISIONOS" }
        return try await resolveWithCache(
            videoId: videoId,
            cacheKeySuffix: "compact_analysis",
            profiles: visionOSProfiles,
            mode: .compactAnalysis
        )
    }

    private func resolveWithCache(
        videoId: String,
        cacheKeySuffix: String,
        profiles: [ClientProfile],
        mode: CandidateSelectionMode
    ) async throws -> ResolvedStream {
        let trimmedId = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw BitChordError.streamUnavailable("Empty video ID.")
        }

        let cacheKey = "\(trimmedId)::\(cacheKeySuffix)"
        if let cached = await cache.validStream(for: cacheKey) {
            return cached
        }

        if let existingTask = await cache.existingTask(for: cacheKey) {
            return try await existingTask.value
        }

        let task = Task<ResolvedStream, Error> {
            let stream = try await self.resolveAcrossClients(
                videoId: trimmedId,
                profiles: profiles,
                mode: mode
            )
            await self.cache.storeStream(stream, for: cacheKey)
            return stream
        }
        await cache.setTask(task, for: cacheKey)

        do {
            let resolved = try await task.value
            await cache.setTask(nil, for: cacheKey)
            return resolved
        } catch {
            await cache.setTask(nil, for: cacheKey)
            throw error
        }
    }

    // MARK: - Multi-Client Resolution

    private func resolveAcrossClients(
        videoId: String,
        profiles: [ClientProfile],
        mode: CandidateSelectionMode
    ) async throws -> ResolvedStream {
        var visitorData = await ensureVisitorData(forceRefresh: false)
        let cookie = await cache.getCookie()
        var hasRefreshedVisitor = false
        var lastFailureReason = "No playable audio formats returned."

        for profile in profiles {
            try Task.checkCancellation()
            if profile.requiresCookie && (cookie == nil || cookie?.isEmpty == true) {
                continue
            }

            do {
                if let stream = try await requestPlayer(
                    videoId: videoId,
                    mode: mode,
                    profile: profile,
                    visitorData: visitorData,
                    cookie: cookie
                ) {
                    return stream
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BitChordError {
                let desc = error.errorDescription ?? ""
                lastFailureReason = "\(profile.name): \(desc)"

                // VISIONOS requires a valid visitorData token; if a cached/stale one triggers
                // bot-check ("Sign in to confirm you're not a bot" / UNPLAYABLE / LOGIN_REQUIRED),
                // refresh visitorData from sw.js_data once and immediately retry this VISIONOS profile.
                if profile.clientName == "VISIONOS",
                   !hasRefreshedVisitor,
                   Self.isLikelyStaleVisitorRejection(desc) {
                    hasRefreshedVisitor = true
                    visitorData = await ensureVisitorData(forceRefresh: true)
                    do {
                        if let retryStream = try await requestPlayer(
                            videoId: videoId,
                            mode: mode,
                            profile: profile,
                            visitorData: visitorData,
                            cookie: cookie
                        ) {
                            return retryStream
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let retryErr as BitChordError {
                        if let retryDesc = retryErr.errorDescription {
                            lastFailureReason = "\(profile.name): \(retryDesc)"
                        }
                    } catch {
                        lastFailureReason = "\(profile.name): \(error.localizedDescription)"
                    }
                }
            } catch {
                lastFailureReason = "\(profile.name): \(error.localizedDescription)"
            }
        }

        throw BitChordError.streamUnavailable(lastFailureReason)
    }

    private static func isLikelyStaleVisitorRejection(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("bot")
            || lower.contains("sign in")
            || lower.contains("unplayable")
            || lower.contains("login_required")
    }

    private func requestPlayer(
        videoId: String,
        mode: CandidateSelectionMode,
        profile: ClientProfile,
        visitorData: String?,
        cookie: String?
    ) async throws -> ResolvedStream? {
        guard let url = URL(string: profile.endpoint) else {
            throw BitChordError.invalidURL
        }

        var playerJS: CachedPlayerJS?
        if profile.supportsCipherFallback {
            playerJS = await ensurePlayerJS(videoId: videoId)
        }

        var clientDict: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
            "gl": Locale.current.region?.identifier ?? "US",
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60
        ]
        if let visitorData { clientDict["visitorData"] = visitorData }
        if let deviceMake = profile.deviceMake { clientDict["deviceMake"] = deviceMake }
        if let deviceModel = profile.deviceModel { clientDict["deviceModel"] = deviceModel }
        if let osName = profile.osName { clientDict["osName"] = osName }
        if let osVersion = profile.osVersion { clientDict["osVersion"] = osVersion }
        if let sdk = profile.androidSdkVersion { clientDict["androidSdkVersion"] = sdk }
        if let platform = profile.platform { clientDict["platform"] = platform }

        var contextDict: [String: Any] = [
            "client": clientDict,
            "user": ["lockedSafetyMode": false]
        ]
        if let embedURL = profile.embedURL {
            contextDict["thirdParty"] = ["embedUrl": embedURL]
        }

        var body: [String: Any] = [
            "videoId": videoId,
            "cpn": Self.generateCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": contextDict
        ]

        if let sts = playerJS?.signatureTimestamp {
            body["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": sts
                ]
            ]
        }

        let payloadData = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let origin = profile.origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
        }
        if let referer = profile.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if profile.requiresCookie, let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let sapisid = InnerTubeClient.extractSAPISID(from: cookie) {
                let authOrigin = profile.origin ?? "https://music.youtube.com"
                request.setValue(
                    InnerTubeClient.sapisidHashHeader(sapisid: sapisid, origin: authOrigin),
                    forHTTPHeaderField: "Authorization"
                )
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BitChordError.networkFailure("Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BitChordError.httpError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BitChordError.parseError("Non-JSON player response")
        }

        if let responseContext = json["responseContext"] as? [String: Any],
           let newVisitor = responseContext["visitorData"] as? String,
           !newVisitor.isEmpty {
            await cache.setVisitorData(newVisitor)
        }

        // Check playabilityStatus
        if let playability = json["playabilityStatus"] as? [String: Any] {
            let status = (playability["status"] as? String ?? "").uppercased()
            if !status.isEmpty && status != "OK" {
                let reason = (playability["reason"] as? String)
                    ?? ((playability["errorScreen"] as? [String: Any])?["playerErrorMessageRenderer"] as? [String: Any])
                        .flatMap { InnerTubeParser.runsText($0["reason"]) }
                    ?? status
                throw BitChordError.streamUnavailable("\(status): \(reason)")
            }
        }

        guard let streamingData = json["streamingData"] as? [String: Any] else {
            return nil
        }

        let videoDetailsDuration: TimeInterval? = {
            guard let vd = json["videoDetails"] as? [String: Any],
                  let secs = Self.parseDouble(vd["lengthSeconds"]),
                  secs > 0 else {
                return nil
            }
            return secs
        }()

        let expiresInSeconds = Self.parseInt64(streamingData["expiresInSeconds"]) ?? (3600 * 5)
        let defaultExpiry = Date().addingTimeInterval(TimeInterval(expiresInSeconds))

        var rawFormats: [[String: Any]] = []
        if let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] {
            rawFormats.append(contentsOf: adaptive)
        }
        if let combined = streamingData["formats"] as? [[String: Any]] {
            rawFormats.append(contentsOf: combined)
        }

        // Parse AVFoundation-compatible audio candidates (`audio/mp4` / AAC `mp4a`)
        var mp4Candidates: [AudioCandidate] = []
        for format in rawFormats {
            guard let candidate = parseCandidate(
                format: format,
                profile: profile,
                defaultExpiry: defaultExpiry,
                fallbackDuration: videoDetailsDuration,
                playerJS: playerJS
            ) else {
                continue
            }
            if candidate.isAVFoundationNative {
                mp4Candidates.append(candidate)
            }
        }

        // Rank candidates and verify direct media URL passes the 1 MiB CDN auth boundary probe
        // before returning/caching (blocks 403-trapped streams like ANDROID_VR 1.65.10).
        let ranked: [AudioCandidate]
        let allowHLSFallback: Bool
        switch mode {
        case .playback(let quality):
            ranked = Self.rankedCandidates(mp4Candidates, quality: quality)
            allowHLSFallback = true
        case .compactAnalysis:
            ranked = Self.rankedCompactAnalysisCandidates(mp4Candidates)
            allowHLSFallback = false
        }

        for candidate in ranked {
            let isReachable: Bool
            if skipMediaProbe {
                isReachable = true
            } else {
                isReachable = await probeDirectStream(candidate: candidate, headers: profile.playbackHeaders)
            }
            if isReachable {
                return candidate.toResolvedStream(clientName: profile.name, headers: profile.playbackHeaders)
            }
        }

        // Fallback to HLS manifest when provided (or when direct MP4 failed the 1 MiB probe)
        if allowHLSFallback,
           let hlsString = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsString) {
            let hlsReachable: Bool
            if skipMediaProbe {
                hlsReachable = true
            } else {
                hlsReachable = await probeHLSManifest(url: hlsURL, headers: profile.playbackHeaders)
            }
            if hlsReachable {
                let expiry = Self.extractExpiry(from: hlsURL) ?? defaultExpiry
                return ResolvedStream(
                    url: hlsURL,
                    mimeType: "application/vnd.apple.mpegurl",
                    codec: "AAC",
                    bitrateKbps: 128,
                    sampleRateHz: 44100,
                    bitDepth: 16,
                    contentLength: nil,
                    expiresAt: expiry,
                    clientName: profile.name,
                    qualityLabel: "HLS",
                    isHLS: true,
                    requestHeaders: profile.playbackHeaders,
                    durationSeconds: videoDetailsDuration
                )
            }
        }

        return nil
    }

    // MARK: - Media Reachability Probe (1 MiB Auth Boundary)

    private func probeDirectStream(candidate: AudioCandidate, headers: [String: String]) async -> Bool {
        let totalLength = candidate.contentLength ?? Self.extractContentLength(from: candidate.url)
        let start: Int64
        if let len = totalLength, len > Self.authBoundaryBytes + Self.probeWindowBytes {
            start = Self.authBoundaryBytes
        } else {
            start = 0
        }

        let end: Int64
        if let len = totalLength, len > 0 {
            end = min(start + Self.probeWindowBytes - 1, len - 1)
        } else {
            end = start + Self.probeWindowBytes - 1
        }
        guard end >= start else { return false }

        var req = URLRequest(url: candidate.url)
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            return false
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isValidType = contentType.hasPrefix("audio/")
            || (!candidate.isAudioOnly && contentType.hasPrefix("video/mp4"))
            || contentType.isEmpty
        guard isValidType else {
            return false
        }
        let expectedMinBytes = min(1024, Int(end - start + 1))
        return data.count >= max(1, expectedMinBytes)
    }

    private func probeHLSManifest(url: URL, headers: [String: String]) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return false
        }
        if let text = String(data: data.prefix(256), encoding: .utf8) {
            return text.contains("#EXTM3U")
        }
        return true
    }

    // MARK: - Candidate Parsing & Quality Selection

    private struct AudioCandidate {
        let itag: Int
        let url: URL
        let mimeType: String
        let codec: String
        let bitrateKbps: Int
        let sampleRateHz: Int?
        let contentLength: Int64?
        let durationSeconds: TimeInterval?
        let expiresAt: Date
        let isAudioOnly: Bool
        let isAVFoundationNative: Bool

        func toResolvedStream(clientName: String, headers: [String: String]) -> ResolvedStream {
            let qualityLabel: String
            switch bitrateKbps {
            case 220...: qualityLabel = "High"
            case 110..<220: qualityLabel = "Standard"
            default: qualityLabel = "Low"
            }
            return ResolvedStream(
                url: url,
                mimeType: mimeType,
                codec: codec,
                bitrateKbps: bitrateKbps,
                sampleRateHz: sampleRateHz ?? 44100,
                bitDepth: 16,
                contentLength: contentLength,
                expiresAt: expiresAt,
                clientName: clientName,
                qualityLabel: qualityLabel,
                isHLS: false,
                requestHeaders: headers,
                durationSeconds: durationSeconds
            )
        }
    }

    private func parseCandidate(
        format: [String: Any],
        profile: ClientProfile,
        defaultExpiry: Date,
        fallbackDuration: TimeInterval?,
        playerJS: CachedPlayerJS?
    ) -> AudioCandidate? {
        guard let rawMime = format["mimeType"] as? String, !rawMime.isEmpty else { return nil }
        let lowerMime = rawMime.lowercased()
        let isAudioOnly = lowerMime.hasPrefix("audio/")
        let isMp4Muxed = lowerMime.hasPrefix("video/mp4") && lowerMime.contains("mp4a")
        guard isAudioOnly || isMp4Muxed else { return nil }

        // Resolve direct URL or decipher signatureCipher / cipher via JavaScriptCore
        let resolvedURL: URL?
        if let direct = format["url"] as? String, let url = URL(string: direct) {
            resolvedURL = url
        } else if profile.supportsCipherFallback,
                  let cipherStr = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
                  let js = playerJS?.jsSource {
            resolvedURL = SignatureDecipherer.decipher(cipherString: cipherStr, playerJS: js)
        } else {
            resolvedURL = nil
        }

        guard let url = resolvedURL else { return nil }

        let itag = (format["itag"] as? NSNumber)?.intValue ?? 0
        let baseMime = rawMime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? rawMime
        let rawCodec = Self.extractCodec(from: rawMime)
        let displayCodec = Self.friendlyCodecName(rawCodec, mimeType: baseMime)

        // AVFoundation natively plays audio/mp4 (AAC/mp4a, itags 141, 140, 139, 258, 327, 18) and ALAC/FLAC/MP3,
        // NOT raw WebM/Opus (`audio/webm`).
        let isNative = (lowerMime.contains("mp4") && (rawCodec.lowercased().contains("mp4a") || [139, 140, 141, 18, 258, 327].contains(itag)))
            || lowerMime.contains("mpeg")
            || lowerMime.contains("flac")
            || lowerMime.contains("alac")

        let avgBitrate = (format["averageBitrate"] as? NSNumber)?.intValue
        let peakBitrate = (format["bitrate"] as? NSNumber)?.intValue
        let bps = avgBitrate ?? peakBitrate ?? Self.estimatedBitrateBps(for: itag)
        let bitrateKbps = max(1, bps / 1000)

        let sampleRateHz = Self.parseInt(format["audioSampleRate"]) ?? 44100
        let contentLength = Self.parseInt64(format["contentLength"]) ?? Self.extractContentLength(from: url)
        let approxDurSec = Self.parseDouble(format["approxDurationMs"]).flatMap { $0 > 0 ? $0 / 1000.0 : nil }
        let urlDurSec = Self.extractDuration(from: url)
        let durationSeconds = approxDurSec ?? urlDurSec ?? fallbackDuration
        let expiresAt = Self.extractExpiry(from: url) ?? defaultExpiry

        return AudioCandidate(
            itag: itag,
            url: url,
            mimeType: baseMime,
            codec: displayCodec,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            contentLength: contentLength,
            durationSeconds: durationSeconds,
            expiresAt: expiresAt,
            isAudioOnly: isAudioOnly,
            isAVFoundationNative: isNative
        )
    }

    private static func rankedCandidates(_ candidates: [AudioCandidate], quality: AudioQuality) -> [AudioCandidate] {
        guard !candidates.isEmpty else { return [] }

        // Prefer audio-only adaptive streams over muxed video+audio streams.
        let audioOnly = candidates.filter(\.isAudioOnly)
        let pool = audioOnly.isEmpty ? candidates : audioOnly

        let ceiling = quality.maxBitrateKbps
        let withinCeiling = pool.filter { $0.bitrateKbps <= ceiling }
        let overCeiling = pool.filter { $0.bitrateKbps > ceiling }

        let preferredSorted: [AudioCandidate]
        if withinCeiling.isEmpty {
            // Every available stream exceeds ceiling (e.g., Low requested when only 128k exists): smallest first.
            preferredSorted = pool.sorted { lhs, rhs in
                if lhs.bitrateKbps != rhs.bitrateKbps { return lhs.bitrateKbps < rhs.bitrateKbps }
                return itagPriority(lhs.itag) > itagPriority(rhs.itag)
            }
        } else {
            // Highest bitrate within ceiling first, breaking ties by preferred AAC itag (141 > 140 > 139),
            // followed by over-ceiling backups if the top choice fails media probe.
            let withinSorted = withinCeiling.sorted { lhs, rhs in
                if lhs.bitrateKbps != rhs.bitrateKbps { return lhs.bitrateKbps > rhs.bitrateKbps }
                return itagPriority(lhs.itag) > itagPriority(rhs.itag)
            }
            let overSorted = overCeiling.sorted { lhs, rhs in
                if lhs.bitrateKbps != rhs.bitrateKbps { return lhs.bitrateKbps < rhs.bitrateKbps }
                return itagPriority(lhs.itag) > itagPriority(rhs.itag)
            }
            preferredSorted = withinSorted + overSorted
        }
        return preferredSorted
    }

    private static func rankedCompactAnalysisCandidates(_ candidates: [AudioCandidate]) -> [AudioCandidate] {
        guard !candidates.isEmpty else { return [] }
        let audioOnly = candidates.filter(\.isAudioOnly)
        let pool = audioOnly.isEmpty ? candidates : audioOnly

        func compactRank(_ candidate: AudioCandidate) -> Int {
            switch candidate.itag {
            case 139: return 0 // 48 kbps HE-AAC (smallest progressive MP4)
            case 140: return 1 // 128 kbps AAC-LC fallback
            default:  return 2
            }
        }

        return pool.sorted { lhs, rhs in
            let rL = compactRank(lhs)
            let rR = compactRank(rhs)
            if rL != rR { return rL < rR }
            if lhs.bitrateKbps != rhs.bitrateKbps { return lhs.bitrateKbps < rhs.bitrateKbps }
            return itagPriority(lhs.itag) > itagPriority(rhs.itag)
        }
    }

    private static func itagPriority(_ itag: Int) -> Int {
        switch itag {
        case 141: return 100 // 256 kbps AAC-LC
        case 258: return 95  // 384 kbps AAC 5.1
        case 140: return 90  // 128 kbps AAC-LC
        case 139: return 80  // 48 kbps HE-AAC
        case 18:  return 30  // muxed mp4 fallback
        default:  return 50
        }
    }

    private static func estimatedBitrateBps(for itag: Int) -> Int {
        switch itag {
        case 141: return 256_000
        case 140: return 128_000
        case 139: return 48_000
        default:  return 128_000
        }
    }

    // MARK: - Visitor Data & Player JS Fetching

    private func ensureVisitorData(forceRefresh: Bool = false) async -> String? {
        if forceRefresh {
            await cache.clearVisitorData()
        } else if let existing = await cache.getVisitorData() {
            return existing
        }
        guard let url = URL(string: "https://www.youtube.com/sw.js_data") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"Cg[A-Za-z0-9_%-]{40,}"#, options: .regularExpression) else {
            return nil
        }
        let visitor = String(text[range])
        await cache.setVisitorData(visitor)
        return visitor
    }

    private func ensurePlayerJS(videoId: String) async -> CachedPlayerJS? {
        if let cached = await cache.getPlayerJS() {
            return cached
        }
        guard let watchURL = URL(string: "https://music.youtube.com/watch?v=\(videoId)") else { return nil }
        var watchReq = URLRequest(url: watchURL)
        watchReq.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        watchReq.timeoutInterval = 10

        guard let (htmlData, htmlResp) = try? await session.data(for: watchReq),
              let http = htmlResp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }

        let jsPathPattern = #"(/s/player/[A-Za-z0-9_-]+/[^"'\s]+base\.js)"#
        guard let match = html.range(of: jsPathPattern, options: .regularExpression) else {
            return nil
        }
        let jsURLString = "https://www.youtube.com\(html[match])"
        guard let jsURL = URL(string: jsURLString) else { return nil }

        var jsReq = URLRequest(url: jsURL)
        jsReq.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        jsReq.timeoutInterval = 12
        guard let (jsData, jsResp) = try? await session.data(for: jsReq),
              let jsHttp = jsResp as? HTTPURLResponse,
              (200..<300).contains(jsHttp.statusCode),
              let jsSource = String(data: jsData, encoding: .utf8) else {
            return nil
        }

        let sts = Self.extractSignatureTimestamp(from: jsSource)
        let entry = CachedPlayerJS(scriptURL: jsURLString, signatureTimestamp: sts, jsSource: jsSource, fetchedAt: Date())
        await cache.setPlayerJS(entry)
        return entry
    }

    // MARK: - Helpers

    private static func extractSignatureTimestamp(from js: String) -> Int? {
        guard let range = js.range(of: #"signatureTimestamp:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let token = js[range].replacingOccurrences(of: "signatureTimestamp:", with: "")
        return Int(token)
    }

    private static func extractCodec(from mimeType: String) -> String {
        guard let range = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) else {
            return ""
        }
        let match = String(mimeType[range])
        return match
            .replacingOccurrences(of: "codecs=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendlyCodecName(_ rawCodec: String, mimeType: String) -> String {
        let lower = rawCodec.lowercased()
        if lower.contains("mp4a.40.5") { return "HE-AAC" }
        if lower.contains("mp4a") { return "AAC" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("alac") { return "ALAC" }
        if lower.contains("flac") { return "FLAC" }
        if !rawCodec.isEmpty { return rawCodec }
        if mimeType.lowercased().contains("mp4") { return "AAC" }
        return "Audio"
    }

    private static func extractExpiry(from url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
              let ts = TimeInterval(raw), ts > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: ts)
    }

    private static func extractDuration(from url: URL) -> TimeInterval? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "dur" })?.value,
              let secs = TimeInterval(raw), secs.isFinite && secs > 0 else {
            return nil
        }
        return secs
    }

    private static func extractContentLength(from url: URL) -> Int64? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "clen" })?.value,
              let bytes = Int64(raw), bytes > 0 else {
            return nil
        }
        return bytes
    }

    private static func parseInt(_ value: Any?) -> Int? {
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String { return Int(str) }
        return nil
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        if let num = value as? NSNumber { return num.int64Value }
        if let str = value as? String { return Int64(str) }
        return nil
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        if let num = value as? NSNumber { return num.doubleValue }
        if let str = value as? String { return Double(str) }
        return nil
    }

    private static func generateCPN() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement() ?? "a" })
    }
}

// MARK: - JavaScriptCore Signature Cipher Decipherer

private enum SignatureDecipherer {
    static func decipher(cipherString: String, playerJS: String) -> URL? {
        var params: [String: String] = [:]
        for pair in cipherString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let val = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            params[key] = val
        }

        guard let baseURLString = params["url"],
              let signature = params["s"],
              !baseURLString.isEmpty else {
            return nil
        }

        let sp = params["sp"] ?? "sig"
        guard let deciphered = runDecipherFunction(signature: signature, playerJS: playerJS),
              !deciphered.isEmpty else {
            return nil
        }

        guard var components = URLComponents(string: baseURLString) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == sp }
        items.append(URLQueryItem(name: sp, value: deciphered))
        components.queryItems = items
        return components.url
    }

    private static func runDecipherFunction(signature: String, playerJS: String) -> String? {
        // Locate the classic YouTube player signature transform function body:
        // e.g. `foo=function(a){a=a.split("");XX.yy(a,3);...return a.join("")}`
        let fnPattern = #"([A-Za-z0-9_$]+)=function\(a\)\{a=a\.split\(""\);([^}]+);return a\.join\(""\)\}"#
        guard let fnRegex = try? NSRegularExpression(pattern: fnPattern),
              let fnMatch = fnRegex.firstMatch(in: playerJS, range: NSRange(playerJS.startIndex..., in: playerJS)),
              let bodyRange = Range(fnMatch.range(at: 2), in: playerJS) else {
            return nil
        }

        let fnBody = String(playerJS[bodyRange])

        // Identify the helper object name referenced in the function body, e.g. `XX.yy(a,3)`
        let helperRefPattern = #"([A-Za-z0-9_$]+)\.[A-Za-z0-9_$]+\(a"#
        var helperDecl = ""
        if let refRegex = try? NSRegularExpression(pattern: helperRefPattern),
           let refMatch = refRegex.firstMatch(in: fnBody, range: NSRange(fnBody.startIndex..., in: fnBody)),
           let objNameRange = Range(refMatch.range(at: 1), in: fnBody) {
            let objName = NSRegularExpression.escapedPattern(for: String(fnBody[objNameRange]))
            let objPattern = #"var \#(objName)=\{(?:[\s\S]*?)\};"#
            if let objRegex = try? NSRegularExpression(pattern: objPattern),
               let objMatch = objRegex.firstMatch(in: playerJS, range: NSRange(playerJS.startIndex..., in: playerJS)),
               let declRange = Range(objMatch.range, in: playerJS) {
                helperDecl = String(playerJS[declRange])
            }
        }

        guard let context = JSContext() else { return nil }
        var hadException = false
        context.exceptionHandler = { _, _ in
            hadException = true
        }

        let script = """
        \(helperDecl)
        function __bitchord_decipher(a) {
            a = a.split("");
            \(fnBody);
            return a.join("");
        }
        """
        context.evaluateScript(script)
        guard !hadException,
              let fn = context.objectForKeyedSubscript("__bitchord_decipher"),
              let result = fn.call(withArguments: [signature]),
              !hadException,
              let str = result.toString(),
              str != "undefined" else {
            return nil
        }
        return str
    }
}
