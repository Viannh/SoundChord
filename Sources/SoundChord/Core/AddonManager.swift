import Foundation

// MARK: - Addon Errors

public enum AddonError: LocalizedError, Sendable {
    case invalidURL
    case notAnAddon(String)
    case duplicateAddon(String)
    case requiresAndroidAttestation
    case addonNotFound
    case streamUnavailable(String)
    case encryptedStreamUnsupported
    case dashStreamUnsupported
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That is not a valid HTTP or HTTPS addon URL."
        case .notAnAddon(let reason):
            return reason
        case .duplicateAddon(let existingName):
            return "This addon is already installed as \"\(existingName)\"."
        case .requiresAndroidAttestation:
            return "This addon requires Android BitChord hardware attestation (bitchordAuth) and cannot be verified on macOS."
        case .addonNotFound:
            return "The configured addon could not be found."
        case .streamUnavailable(let reason):
            return reason
        case .encryptedStreamUnsupported:
            return "Addon returned a DRM-encrypted stream, which is not supported."
        case .dashStreamUnsupported:
            return "Addon returned a DASH (.mpd) manifest, which macOS AVPlayer cannot play natively."
        case .networkError(let reason):
            return reason
        }
    }
}

// MARK: - Move Direction

public enum AddonMoveDirection: Sendable {
    case up
    case down
}

// MARK: - Flexible JSON Decoding Helpers

private enum FlexibleJSON {
    static func decodeFlag(from container: KeyedDecodingContainer<AddonManifest.CodingKeys>, forKey key: AddonManifest.CodingKeys) -> Bool? {
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolVal
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal != 0
        }
        if let doubleVal = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleVal != 0
        }
        if let strVal = try? container.decodeIfPresent(String.self, forKey: key) {
            switch strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default:
                if let num = Double(strVal) { return num != 0 }
                return nil
            }
        }
        return nil
    }

    static func decodeScalarString<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolVal ? "true" : "false"
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(intVal)
        }
        if let doubleVal = try? container.decodeIfPresent(Double.self, forKey: key) {
            if doubleVal.rounded() == doubleVal {
                return String(Int(doubleVal))
            }
            return String(doubleVal)
        }
        return nil
    }

    static func decodeEncryptedFlag(from container: KeyedDecodingContainer<AddonStream.CodingKeys>, forKey key: AddonStream.CodingKeys) -> Bool {
        if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolVal
        }
        if let strVal = try? container.decodeIfPresent(String.self, forKey: key) {
            let lowered = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !lowered.isEmpty && lowered != "false" && lowered != "none" && lowered != "0"
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal != 0
        }
        return false
    }
}

// MARK: - Addon Protocol Models

public struct AddonQualityOption: Codable, Identifiable, Hashable, Sendable {
    public var id: String { value }
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct AddonSettingOption: Codable, Hashable, Sendable {
    public var value: String?
    public var label: String?

    enum CodingKeys: String, CodingKey {
        case value, label
    }

    public init(value: String? = nil, label: String? = nil) {
        self.value = value
        self.label = label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = FlexibleJSON.decodeScalarString(from: container, forKey: .value)
        self.label = FlexibleJSON.decodeScalarString(from: container, forKey: .label)
    }
}

public struct AddonSetting: Codable, Hashable, Sendable {
    public var key: String
    public var type: String?
    public var label: String?
    public var defaultValue: String?
    public var options: [AddonSettingOption]

    enum CodingKeys: String, CodingKey {
        case key, type, label
        case defaultValue = "default"
        case options
    }

    public init(
        key: String,
        type: String? = nil,
        label: String? = nil,
        defaultValue: String? = nil,
        options: [AddonSettingOption] = []
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.defaultValue = defaultValue
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? ""
        self.type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.label = try? container.decodeIfPresent(String.self, forKey: .label)
        self.defaultValue = FlexibleJSON.decodeScalarString(from: container, forKey: .defaultValue)
        self.options = (try? container.decodeIfPresent([AddonSettingOption].self, forKey: .options)) ?? []
    }
}

public struct AddonManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var icon: String?
    public var resources: [String]
    public var settings: [AddonSetting]
    public var allowDownloads: Bool
    public var checkValidLossless: Bool
    public var requiresBitChordAuth: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, resources, settings
        case allowDownloads
        case checkValidLossless
        case bitchordAuth
    }

    public init(
        id: String = "",
        name: String = "",
        version: String = "",
        description: String = "",
        icon: String? = nil,
        resources: [String] = [],
        settings: [AddonSetting] = [],
        allowDownloads: Bool = true,
        checkValidLossless: Bool = false,
        requiresBitChordAuth: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.resources = resources
        self.settings = settings
        self.allowDownloads = allowDownloads
        self.checkValidLossless = checkValidLossless
        self.requiresBitChordAuth = requiresBitChordAuth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        self.description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.icon = try? container.decodeIfPresent(String.self, forKey: .icon)
        self.resources = (try? container.decodeIfPresent([String].self, forKey: .resources)) ?? []
        self.settings = (try? container.decodeIfPresent([AddonSetting].self, forKey: .settings)) ?? []
        self.allowDownloads = FlexibleJSON.decodeFlag(from: container, forKey: .allowDownloads) ?? true
        self.checkValidLossless = FlexibleJSON.decodeFlag(from: container, forKey: .checkValidLossless) ?? false
        self.requiresBitChordAuth = FlexibleJSON.decodeFlag(from: container, forKey: .bitchordAuth) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(resources, forKey: .resources)
        try container.encode(settings, forKey: .settings)
        try container.encode(allowDownloads, forKey: .allowDownloads)
        try container.encode(checkValidLossless, forKey: .checkValidLossless)
        try container.encode(requiresBitChordAuth, forKey: .bitchordAuth)
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    public var isPlayable: Bool {
        resources.isEmpty || resources.contains { $0.caseInsensitiveCompare("search") == .orderedSame }
    }

    public var qualityOptions: [AddonQualityOption] {
        guard let qualitySetting = settings.first(where: { $0.key == "quality" }) else {
            return []
        }
        var seen = Set<String>()
        var result: [AddonQualityOption] = []
        for option in qualitySetting.options {
            guard let val = option.value, !val.isEmpty, !seen.contains(val) else { continue }
            seen.insert(val)
            result.append(AddonQualityOption(value: val, label: option.label ?? val))
        }
        return result.count > 1 ? result : []
    }

    public var defaultSettingsMap: [String: String] {
        var map: [String: String] = [:]
        for setting in settings where !setting.key.isEmpty {
            if let def = setting.defaultValue {
                map[setting.key] = def
            }
        }
        return map
    }
}

public struct AddonConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var manifestURL: String
    public var isEnabled: Bool
    public var preferredQuality: String?
    public var allowDownloads: Bool
    public var checkValidLossless: Bool
    public var requiresBitChordAuth: Bool
    public var version: String
    public var iconURL: String?
    public var description: String
    public var qualityOptions: [AddonQualityOption]
    public var defaultSettings: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        manifestURL: String? = nil,
        isEnabled: Bool = true,
        preferredQuality: String? = nil,
        allowDownloads: Bool = true,
        checkValidLossless: Bool = false,
        requiresBitChordAuth: Bool = false,
        version: String = "",
        iconURL: String? = nil,
        description: String = "",
        qualityOptions: [AddonQualityOption] = [],
        defaultSettings: [String: String] = [:]
    ) {
        let normalized = AddonClient.normalizeBase(baseURL)
        self.id = id
        self.name = name
        self.baseURL = normalized
        self.manifestURL = manifestURL ?? AddonClient.manifestURL(forBase: normalized)
        self.isEnabled = isEnabled
        self.preferredQuality = preferredQuality
        self.allowDownloads = allowDownloads
        self.checkValidLossless = checkValidLossless
        self.requiresBitChordAuth = requiresBitChordAuth
        self.version = version
        self.iconURL = iconURL
        self.description = description
        self.qualityOptions = qualityOptions
        self.defaultSettings = defaultSettings
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: baseURL)?.host, !host.isEmpty { return host }
        return "Custom Addon"
    }

    public var activeQuality: AddonQualityOption? {
        if let picked = preferredQuality, let match = qualityOptions.first(where: { $0.value == picked }) {
            return match
        }
        return qualityOptions.first
    }

    public var resolvedIconURL: URL? {
        guard let iconURL, !iconURL.isEmpty else { return nil }
        return URL(string: iconURL)
    }
}

public struct AddonSearchResponse: Codable, Hashable, Sendable {
    public var tracks: [AddonTrack]

    public init(tracks: [AddonTrack] = []) {
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks = (try? container.decodeIfPresent([AddonTrack].self, forKey: .tracks)) ?? []
    }
}

public struct AddonTrack: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?
    public var artworkURL: String?
    public var albumArtworkURL: String?
    public var format: String
    public var audioQuality: String
    public var audioMode: String?
    public var audioModes: [String]
    public var atmos: Bool?
    public var streamURL: String?
    public var bitDepth: Int?
    public var sampleRate: Double?
    public var isrc: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, artworkURL, albumArtworkURL
        case format, audioQuality, audioMode, audioModes, atmos, streamURL
        case bitDepth, sampleRate, isrc
    }

    public init(
        id: String = "",
        title: String = "",
        artist: String = "",
        album: String = "",
        duration: Double? = nil,
        artworkURL: String? = nil,
        albumArtworkURL: String? = nil,
        format: String = "",
        audioQuality: String = "",
        audioMode: String? = nil,
        audioModes: [String] = [],
        atmos: Bool? = nil,
        streamURL: String? = nil,
        bitDepth: Int? = nil,
        sampleRate: Double? = nil,
        isrc: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.albumArtworkURL = albumArtworkURL
        self.format = format
        self.audioQuality = audioQuality
        self.audioMode = audioMode
        self.audioModes = audioModes
        self.atmos = atmos
        self.streamURL = streamURL
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.isrc = isrc
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = FlexibleJSON.decodeScalarString(from: container, forKey: .id) ?? ""
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.artist = (try? container.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        self.album = (try? container.decodeIfPresent(String.self, forKey: .album)) ?? ""
        self.duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
        self.artworkURL = try? container.decodeIfPresent(String.self, forKey: .artworkURL)
        self.albumArtworkURL = try? container.decodeIfPresent(String.self, forKey: .albumArtworkURL)
        self.format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? ""
        self.audioQuality = (try? container.decodeIfPresent(String.self, forKey: .audioQuality)) ?? ""
        self.audioMode = try? container.decodeIfPresent(String.self, forKey: .audioMode)
        self.audioModes = (try? container.decodeIfPresent([String].self, forKey: .audioModes)) ?? []
        self.atmos = try? container.decodeIfPresent(Bool.self, forKey: .atmos)
        self.streamURL = try? container.decodeIfPresent(String.self, forKey: .streamURL)
        if let bdInt = try? container.decodeIfPresent(Int.self, forKey: .bitDepth) {
            self.bitDepth = bdInt
        } else if let bdDouble = try? container.decodeIfPresent(Double.self, forKey: .bitDepth) {
            self.bitDepth = Int(bdDouble)
        } else {
            self.bitDepth = nil
        }
        self.sampleRate = try? container.decodeIfPresent(Double.self, forKey: .sampleRate)
        self.isrc = try? container.decodeIfPresent(String.self, forKey: .isrc)
    }

    public var durationSeconds: TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    public var resolvedArtworkURL: URL? {
        if let raw = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        if let raw = albumArtworkURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return nil
    }

    public var normalizedSampleRateHz: Int? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        return sampleRate < 1000 ? Int((sampleRate * 1000).rounded()) : Int(sampleRate.rounded())
    }

    public var isDolbyAtmos: Bool {
        if atmos == true { return true }
        let combined = "\(audioQuality) \(audioMode ?? "") \(audioModes.joined(separator: " ")) \(format)".lowercased()
        return combined.contains("atmos") || combined.contains("dolby") || combined.contains("eac3") || combined.contains("ec-3")
    }

    public var isHiRes: Bool {
        if isDolbyAtmos { return false }
        if let bitDepth, bitDepth >= 24 { return true }
        if let hz = normalizedSampleRateHz, hz >= 88_200 { return true }
        let combined = "\(audioQuality) \(format)".lowercased()
        return combined.contains("hi_res") || combined.contains("hi-res") || combined.contains("hires") || combined.contains("24-bit") || combined.contains("24bit")
    }

    public var isLossless: Bool {
        if isDolbyAtmos { return false }
        let combined = "\(audioQuality) \(format)".lowercased()
        return combined.contains("lossless") || combined.contains("flac") || combined.contains("alac") || combined.contains("wav") || combined.contains("hi_res") || combined.contains("hi-res")
    }

    public var inferredCodec: String? {
        if isDolbyAtmos { return "eac3-joc" }
        let fmt = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["flac", "alac", "wav", "aiff", "mp3", "aac", "m4a", "mp4", "opus", "ogg"].contains(fmt) {
            return fmt
        }
        return isLossless ? "flac" : nil
    }

    public var formattedQualityBadge: String? {
        if isDolbyAtmos { return "Dolby Atmos" }
        if isHiRes {
            var parts = ["Hi-Res"]
            if let bd = bitDepth, bd > 0 { parts.append("\(bd)-bit") }
            if let hz = normalizedSampleRateHz, hz > 0 {
                let khz = Double(hz) / 1000.0
                let formatted = khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
                parts.append(formatted)
            }
            return parts.joined(separator: " · ")
        }
        if isLossless {
            if let bd = bitDepth, let hz = normalizedSampleRateHz, bd > 0, hz > 0 {
                let khz = Double(hz) / 1000.0
                let formatted = khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
                return "FLAC · \(bd)-bit · \(formatted)"
            }
            return "Lossless"
        }
        if !audioQuality.isEmpty {
            return audioQuality.uppercased()
        }
        return format.isEmpty ? nil : format.uppercased()
    }
}

public struct AddonStream: Codable, Hashable, Sendable {
    public var url: String
    public var format: String
    public var quality: String
    public var streamQuality: String
    public var audioQuality: String
    public var codec: String?
    public var fileCodec: String?
    public var container: String?
    public var containerFormat: String?
    public var manifest: String?
    public var mediaType: String?
    public var mimeType: String?
    public var encrypted: Bool
    public var sampleRate: Double?
    public var bitDepth: Double?
    public var bitrate: Double?
    public var expiresAt: Double?
    public var audioMode: String?
    public var audioModes: [String]
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case url, format, quality, streamQuality, audioQuality
        case codec, fileCodec, container, containerFormat
        case manifest, mediaType, mimeType, encrypted
        case sampleRate, bitDepth, bitrate, expiresAt
        case audioMode, audioModes, error
    }

    public init(
        url: String = "",
        format: String = "",
        quality: String = "",
        streamQuality: String = "",
        audioQuality: String = "",
        codec: String? = nil,
        fileCodec: String? = nil,
        container: String? = nil,
        containerFormat: String? = nil,
        manifest: String? = nil,
        mediaType: String? = nil,
        mimeType: String? = nil,
        encrypted: Bool = false,
        sampleRate: Double? = nil,
        bitDepth: Double? = nil,
        bitrate: Double? = nil,
        expiresAt: Double? = nil,
        audioMode: String? = nil,
        audioModes: [String] = [],
        error: String? = nil
    ) {
        self.url = url
        self.format = format
        self.quality = quality
        self.streamQuality = streamQuality
        self.audioQuality = audioQuality
        self.codec = codec
        self.fileCodec = fileCodec
        self.container = container
        self.containerFormat = containerFormat
        self.manifest = manifest
        self.mediaType = mediaType
        self.mimeType = mimeType
        self.encrypted = encrypted
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.expiresAt = expiresAt
        self.audioMode = audioMode
        self.audioModes = audioModes
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        self.format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? ""
        self.quality = (try? container.decodeIfPresent(String.self, forKey: .quality)) ?? ""
        self.streamQuality = (try? container.decodeIfPresent(String.self, forKey: .streamQuality)) ?? ""
        self.audioQuality = (try? container.decodeIfPresent(String.self, forKey: .audioQuality)) ?? ""
        self.codec = try? container.decodeIfPresent(String.self, forKey: .codec)
        self.fileCodec = try? container.decodeIfPresent(String.self, forKey: .fileCodec)
        self.container = try? container.decodeIfPresent(String.self, forKey: .container)
        self.containerFormat = try? container.decodeIfPresent(String.self, forKey: .containerFormat)
        self.manifest = try? container.decodeIfPresent(String.self, forKey: .manifest)
        self.mediaType = try? container.decodeIfPresent(String.self, forKey: .mediaType)
        self.mimeType = try? container.decodeIfPresent(String.self, forKey: .mimeType)
        self.encrypted = FlexibleJSON.decodeEncryptedFlag(from: container, forKey: .encrypted)
        self.sampleRate = try? container.decodeIfPresent(Double.self, forKey: .sampleRate)
        self.bitDepth = try? container.decodeIfPresent(Double.self, forKey: .bitDepth)
        self.bitrate = try? container.decodeIfPresent(Double.self, forKey: .bitrate)
        self.expiresAt = try? container.decodeIfPresent(Double.self, forKey: .expiresAt)
        self.audioMode = try? container.decodeIfPresent(String.self, forKey: .audioMode)
        self.audioModes = (try? container.decodeIfPresent([String].self, forKey: .audioModes)) ?? []
        self.error = try? container.decodeIfPresent(String.self, forKey: .error)
    }

    public var statedCodec: String? {
        let raw = (codec?.isEmpty == false ? codec : fileCodec)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw?.isEmpty == false ? raw : nil
    }

    public var statedContainer: String? {
        let raw = (container?.isEmpty == false ? container : containerFormat)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw?.isEmpty == false ? raw : nil
    }

    public var qualityText: String {
        "\(quality) \(streamQuality) \(audioQuality) \(format)"
    }

    /// Returns `"hls"`, `"dash"`, or `nil` for progressive audio files.
    public var transport: String? {
        let candidates = [manifest, mediaType, format.isEmpty ? nil : format].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for value in candidates where !value.isEmpty {
            switch value {
            case "hls", "m3u8", "application/x-mpegurl", "application/vnd.apple.mpegurl":
                return "hls"
            case "dash", "mpd", "application/dash+xml":
                return "dash"
            case "none":
                return nil
            default:
                continue
            }
        }
        let pathLower = URL(string: url)?.path.lowercased() ?? ""
        if pathLower.hasSuffix(".m3u8") { return "hls" }
        if pathLower.hasSuffix(".mpd") { return "dash" }
        return nil
    }

    public var isDolbyAtmos: Bool {
        let combined = "\(qualityText) \(audioMode ?? "") \(audioModes.joined(separator: " ")) \(statedCodec ?? "")".lowercased()
        return combined.contains("atmos") || combined.contains("dolby") || combined.contains("eac3") || combined.contains("ec-3")
    }

    public var normalizedSampleRateHz: Int? {
        if let sampleRate, sampleRate > 0 {
            return sampleRate < 1000 ? Int((sampleRate * 1000).rounded()) : Int(sampleRate.rounded())
        }
        let pattern = #"([\d.]+)\s*kHz"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: qualityText, range: NSRange(qualityText.startIndex..., in: qualityText)),
           let range = Range(match.range(at: 1), in: qualityText),
           let khz = Double(qualityText[range]), khz > 0 {
            return Int((khz * 1000).rounded())
        }
        return nil
    }

    public var normalizedBitDepth: Int? {
        if let bitDepth, bitDepth > 0 {
            return Int(bitDepth.rounded())
        }
        let pattern = #"(\d{1,2})\s*-?\s*bit"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: qualityText, range: NSRange(qualityText.startIndex..., in: qualityText)),
           let range = Range(match.range(at: 1), in: qualityText),
           let bits = Int(qualityText[range]), (8...32).contains(bits) {
            return bits
        }
        return nil
    }

    public var normalizedBitrateKbps: Int? {
        if let bitrate, bitrate > 0 {
            return bitrate > 3_000 ? Int((bitrate / 1000).rounded()) : Int(bitrate.rounded())
        }
        let pattern = #"(\d{2,4})\s*kbps"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: qualityText, range: NSRange(qualityText.startIndex..., in: qualityText)),
           let range = Range(match.range(at: 1), in: qualityText),
           let kbps = Int(qualityText[range]), kbps > 0 {
            return kbps
        }
        return nil
    }

    private static let knownCodecs: Set<String> = [
        "flac", "alac", "wav", "aiff", "mp3", "aac", "he-aac", "m4a", "mp4",
        "ogg", "opus", "vorbis", "webm", "eac3-joc", "ec3-joc"
    ]
    private static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff"]

    public var resolvedCodec: String {
        if let c = statedCodec, Self.knownCodecs.contains(c) { return c }
        if let cont = statedContainer, ["flac", "wav", "mp3", "aiff"].contains(cont) { return cont }
        if let mime = mimeType?.split(separator: "/").last?.split(separator: ";").first {
            let clean = String(mime).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.knownCodecs.contains(clean) { return clean }
        }
        if isDolbyAtmos { return "eac3-joc" }
        let qtLower = qualityText.lowercased()
        if qtLower.contains("flac") || qtLower.contains("lossless") || qtLower.contains("hi-res") || qtLower.contains("hi_res") {
            return "flac"
        }
        if let ext = URL(string: url)?.pathExtension.lowercased(), Self.knownCodecs.contains(ext) {
            return ext
        }
        return "aac"
    }

    public var isLossless: Bool {
        Self.losslessCodecs.contains(resolvedCodec)
    }

    public var resolvedMimeType: String {
        if let mimeType, !mimeType.isEmpty { return mimeType }
        switch resolvedCodec {
        case "flac": return "audio/flac"
        case "alac", "m4a", "mp4", "aac", "he-aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aiff": return "audio/aiff"
        case "opus", "ogg", "vorbis": return "audio/ogg"
        case "eac3-joc", "ec3-joc": return "audio/eac3"
        default: return "audio/flac"
        }
    }

    public var resolvedQualityLabel: String {
        if isDolbyAtmos { return "Dolby Atmos" }
        if isLossless {
            let bits = normalizedBitDepth ?? 16
            let hz = normalizedSampleRateHz ?? 44_100
            if bits >= 24 || hz >= 88_200 {
                return "Hi-Res Lossless"
            }
            return "Lossless"
        }
        let kbps = normalizedBitrateKbps ?? 0
        if kbps >= 256 { return "High Quality" }
        if kbps > 0 { return "\(kbps) kbps" }
        return "Standard"
    }

    public var resolvedExpiryDate: Date {
        if let expiresAt, expiresAt > 0 {
            // Timestamps > 1e12 are milliseconds, otherwise seconds.
            let seconds = expiresAt > 1_000_000_000_000 ? expiresAt / 1000.0 : expiresAt
            let date = Date(timeIntervalSince1970: seconds)
            if date > Date().addingTimeInterval(30) {
                return min(date, Date().addingTimeInterval(3600))
            }
        }
        return Date().addingTimeInterval(300)
    }
}

public enum AddonHealthStatus: Hashable, Sendable {
    case unknown
    case checking
    case connected(version: String)
    case requiresAndroidAttestation
    case unreachable(String)

    public var label: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking…"
        case .connected(let version):
            return version.isEmpty ? "Connected" : "Connected · v\(version)"
        case .requiresAndroidAttestation:
            return "Requires Android BitChord Attestation"
        case .unreachable(let reason):
            return reason.isEmpty ? "Unreachable" : reason
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct AddonProbeResult: Hashable, Sendable {
    public var manifest: AddonManifest
    public var baseURL: String
    public var manifestURL: String
    public var health: AddonHealthStatus
    public var hadManifest: Bool

    public init(
        manifest: AddonManifest,
        baseURL: String,
        manifestURL: String,
        health: AddonHealthStatus,
        hadManifest: Bool
    ) {
        self.manifest = manifest
        self.baseURL = baseURL
        self.manifestURL = manifestURL
        self.health = health
        self.hadManifest = hadManifest
    }
}

public struct CuratedAddonPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let manifestURL: String?
    public let setupURL: String?
    public let category: String
    public let isDirectInstall: Bool
    public let note: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        manifestURL: String? = nil,
        setupURL: String? = nil,
        category: String,
        isDirectInstall: Bool,
        note: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.manifestURL = manifestURL
        self.setupURL = setupURL
        self.category = category
        self.isDirectInstall = isDirectInstall
        self.note = note
    }
}

// MARK: - TrackMatcher (Upstream-Faithful Cross-Source Recording Matching)

public enum TrackMatcher: Sendable {
    private static let versionWords: Set<String> = [
        "live", "remix", "acoustic", "instrumental", "karaoke", "demo",
        "unplugged", "cover", "slowed", "sped", "reverb", "nightcore",
        "acapella", "mashup", "medley", "orchestral", "piano", "lofi",
        "8d", "vip", "dub", "extended", "club", "clean", "edit", "mix"
    ]

    private static let trailingTakes: Set<String> = [
        "instrumental", "karaoke", "remix", "acoustic", "acapella", "slowed", "nightcore"
    ]

    private static let neutralSegments: Set<String> = [
        "officialaudio", "officialvideo", "officialmusicvideo", "officiallyricvideo",
        "lyricvideo", "lyrics", "audio", "video", "albumversion", "radioedit",
        "explicit", "remastered", "remaster", "deluxe", "deluxeedition",
        "bonus", "bonustrack", "singleversion", "original", "originalmix",
        "hd", "hq", "4k", "visualizer", "officialvisualizer", "explicitversion"
    ]

    private static let trailingNoise: Set<String> = [
        "audio", "video", "official", "lyrics", "lyric", "song", "full", "hd", "hq", "mv"
    ]

    private static let artistSeparators = try! NSRegularExpression(
        pattern: #"\s*(?:,|&|/|;|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b|\band\b|\bx\b|×)\s*"#,
        options: .caseInsensitive
    )

    private static let featuringTail = try! NSRegularExpression(
        pattern: #"\s+(?:feat\.?|ft\.?|featuring|part\.)\s+.*$"#,
        options: .caseInsensitive
    )

    private static let bracketRegex = try! NSRegularExpression(
        pattern: #"\(([^()]*)\)|\[([^\[\]]*)\]"#,
        options: []
    )

    private static let dashRegex = try! NSRegularExpression(
        pattern: #"\s+[-–—|]\s+"#,
        options: []
    )

    public struct TitleParts: Hashable, Sendable {
        public let words: [String]
        public let core: String
        public let versions: Set<String>
    }

    public static func queries(for track: Track) -> [String] {
        let parsed = parseTitle(track.title, artist: track.artist)
        let searchableTitle = (parsed.words + parsed.versions.sorted()).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchableTitle.isEmpty else { return [] }

        let primaryArtist = primaryArtistName(from: track.artist)
        var out: [String] = []
        if !primaryArtist.isEmpty {
            out.append("\(searchableTitle) \(primaryArtist)")
        }
        out.append(searchableTitle)

        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    public static func parseTitle(_ raw: String, artist: String = "") -> TitleParts {
        var text = normalizeText(raw)
        var versions = Set<String>()

        // Extract innermost brackets up to 3 passes.
        for _ in 0..<3 {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = bracketRegex.matches(in: text, range: nsRange)
            if matches.isEmpty { break }
            var replaced = text
            for match in matches.reversed() {
                let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                if let r = Range(innerRange, in: replaced) {
                    classifyAside(String(replaced[r]), into: &versions)
                }
                if let fullRange = Range(match.range, in: replaced) {
                    replaced.replaceSubrange(fullRange, with: " ")
                }
            }
            text = replaced
        }

        // Unbalanced opening bracket
        if let openIdx = text.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            classifyAside(String(text[openIdx...]), into: &versions)
            text = String(text[..<openIdx])
        }

        // Dash-separated tails ("Song - Live", "Artist - Title")
        for _ in 0..<2 {
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let match = dashRegex.firstMatch(in: text, range: nsRange),
                  let range = Range(match.range, in: text) else { break }
            let head = String(text[..<range.lowerBound])
            let tail = String(text[range.upperBound...])
            if isArtistPrefix(head, artist: artist) {
                text = tail
            } else {
                classifyAside(tail, into: &versions)
                text = head
            }
        }

        // Strip trailing feat./ft. credits
        let featRange = NSRange(text.startIndex..., in: text)
        text = featuringTail.stringByReplacingMatches(in: text, range: featRange, withTemplate: " ")

        var words = tokenize(text)
        while words.count > 1, let last = words.last {
            if trailingNoise.contains(last) {
                words.removeLast()
            } else if trailingTakes.contains(last) {
                versions.insert(last)
                words.removeLast()
            } else {
                break
            }
        }

        let core = words.joined()
        return TitleParts(words: words, core: core, versions: versions)
    }

    public static func sharesArtist(_ wanted: String, _ got: String) -> Bool {
        let wantSet = artistTokenSets(wanted)
        let gotSet = artistTokenSets(got)
        guard !wantSet.isEmpty, !gotSet.isEmpty else { return false }
        for w in wantSet {
            for g in gotSet {
                if containsWordRun(outer: w, inner: g) || containsWordRun(outer: g, inner: w) {
                    return true
                }
            }
        }
        return false
    }

    public static func score(candidate: AddonTrack, target: Track, durationToleranceSec: Double = 6.0) -> Int? {
        let wanted = parseTitle(target.title, artist: target.artist)
        let got = parseTitle(candidate.title, artist: candidate.artist)
        guard !wanted.core.isEmpty, !got.core.isEmpty else { return nil }

        let titleMatches: Bool
        if wanted.core == got.core {
            titleMatches = true
        } else if wanted.core.count > 3 && got.core.count > 3 {
            titleMatches = wanted.core.contains(got.core) || got.core.contains(wanted.core)
        } else {
            titleMatches = false
        }
        guard titleMatches else { return nil }

        // Version markers (live, remix, acoustic, instrumental, slowed, sped up, karaoke, demo) must agree!
        let albumVersions = candidate.album.isEmpty ? Set<String>() : parseTitle(candidate.album).versions
        let noVocalTakes: Set<String> = ["instrumental", "karaoke", "acapella"]
        let effectiveVersions = got.versions
            .union(albumVersions.intersection(noVocalTakes))
            .union(albumVersions.intersection(wanted.versions))
        guard wanted.versions == effectiveVersions else { return nil }

        // Duration check when both sides report duration
        let targetDur = target.duration
        let candDur = candidate.durationSeconds
        var durationScore = 0
        if targetDur > 0 && candDur > 0 {
            let drift = abs(targetDur - candDur)
            if drift > max(1.0, durationToleranceSec) {
                return nil
            }
            durationScore = drift <= 2.0 ? 35 : 15
        }

        // Artist overlap check (or exact <= 2s master fallback when credits differ e.g. composer vs singer)
        let wantArtists = artistTokenSets(target.artist)
        let gotArtists = artistTokenSets(candidate.artist)
        var artistScore = 0
        if !wantArtists.isEmpty && !gotArtists.isEmpty {
            if sharesArtist(target.artist, candidate.artist) {
                artistScore = wantArtists == gotArtists ? 50 : 35
            } else if targetDur > 0 && candDur > 0 && abs(targetDur - candDur) <= 2.0 && wanted.core == got.core {
                artistScore = 5
            } else {
                return nil
            }
        }

        // Album tie-breaker
        var albumBonus = 0
        if let wantAlbum = target.album, !wantAlbum.isEmpty, !candidate.album.isEmpty {
            let wa = tokenize(normalizeText(wantAlbum)).joined()
            let ga = tokenize(normalizeText(candidate.album)).joined()
            if !wa.isEmpty && wa == ga { albumBonus = 20 }
        }

        // Exact title tie-breaker + quality preference (Hi-Res > Lossless > Lossy)
        let exactTitleBonus = wanted.core == got.core ? 20 : 0
        let qualityBonus: Int
        if candidate.isHiRes {
            qualityBonus = 18
        } else if candidate.isLossless {
            qualityBonus = 14
        } else if candidate.isDolbyAtmos {
            qualityBonus = 4
        } else {
            qualityBonus = 0
        }

        return 100 + artistScore + durationScore + albumBonus + exactTitleBonus + qualityBonus
    }

    public static func ranked(candidates: [AddonTrack], target: Track, durationToleranceSec: Double = 6.0) -> [AddonTrack] {
        let scored: [(AddonTrack, Int)] = candidates.compactMap { track in
            guard let s = score(candidate: track, target: target, durationToleranceSec: durationToleranceSec) else { return nil }
            return (track, s)
        }
        // Prefer candidates that explicitly share an artist if any exist.
        let credited = scored.filter { sharesArtist(target.artist, $0.0.artist) }
        let pool = credited.isEmpty ? scored : credited
        return pool.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func normalizeText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "「", with: "(")
            .replacingOccurrences(of: "」", with: ")")
            .replacingOccurrences(of: "『", with: "(")
            .replacingOccurrences(of: "』", with: ")")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    private static func tokenize(_ text: String) -> [String] {
        let cleaned = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func classifyAside(_ segment: String, into versions: inout Set<String>) {
        let words = tokenize(segment)
        guard !words.isEmpty else { return }
        let joined = words.joined()
        if neutralSegments.contains(joined) { return }
        if joined.contains("spedup") {
            versions.insert("sped")
        }
        if joined.contains("slowed") {
            versions.insert("slowed")
        }
        for w in words where versionWords.contains(w) {
            versions.insert(w)
        }
    }

    private static func primaryArtistName(from artist: String) -> String {
        let norm = normalizeText(artist)
        let nsRange = NSRange(norm.startIndex..., in: norm)
        let firstPart: String
        if let match = artistSeparators.firstMatch(in: norm, range: nsRange),
           let range = Range(match.range, in: norm) {
            firstPart = String(norm[..<range.lowerBound])
        } else {
            firstPart = norm
        }
        return firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func artistTokenSets(_ value: String) -> Set<[String]> {
        let norm = normalizeText(value)
        let nsRange = NSRange(norm.startIndex..., in: norm)
        let replaced = artistSeparators.stringByReplacingMatches(in: norm, range: nsRange, withTemplate: "\u{001F}")
        let parts = replaced.components(separatedBy: "\u{001F}")
        var out = Set<[String]>()
        for part in parts {
            let tokens = tokenize(part).filter { $0.count > 1 }
            if !tokens.isEmpty { out.insert(tokens) }
        }
        return out
    }

    private static func isArtistPrefix(_ head: String, artist: String) -> Bool {
        guard !artist.isEmpty else { return false }
        let headWords = tokenize(head)
        guard !headWords.isEmpty else { return false }
        let artistWords = Set(tokenize(normalizeText(artist)))
        return headWords.allSatisfy { artistWords.contains($0) }
    }

    private static func containsWordRun(outer: [String], inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        for start in 0...(outer.count - inner.count) {
            if Array(outer[start..<(start + inner.count)]) == inner {
                return true
            }
        }
        return false
    }
}

// MARK: - AddonClient (HTTP JSON Addon Protocol)

public actor AddonClient {
    private static let userAgent = "SoundChord/2.0.0"
    private static let manifestTTL: TimeInterval = 10 * 60
    private static let searchTTL: TimeInterval = 10 * 60
    private static let streamTTL: TimeInterval = 5 * 60
    private static let maxRateLimitRetries = 2
    private static let maxBackoffSec: TimeInterval = 8.0

    private static let highQualityWords = ["high", "320", "normal", "standard"]
    private static let lowQualityWords = ["low", "96", "128", "min"]

    private struct CacheEntry<T: Sendable>: Sendable {
        let value: T
        let expiresAt: Date
    }

    private let session: URLSession
    private var manifestCache: [String: CacheEntry<AddonManifest>] = [:]
    private var searchCache: [String: CacheEntry<[AddonTrack]>] = [:]
    private var streamCache: [String: CacheEntry<AddonStream>] = [:]
    private var quietUntilByHost: [String: Date] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 45
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: URL Normalization & Deduplication

    /// Strips trailing `/manifest.json` (or any `*.json` filename) and trailing slashes
    /// while preserving case-sensitive token path segments.
    public nonisolated static func normalizeBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed.contains("://") else { return trimmed }

        // Strip query string if someone pasted ?... onto a manifest URL
        let withoutQuery = trimmed.components(separatedBy: "?").first ?? trimmed
        if let lastSlash = withoutQuery.lastIndex(of: "/") {
            let lastSegment = String(withoutQuery[withoutQuery.index(after: lastSlash)...])
            if lastSegment.lowercased().hasSuffix(".json") {
                var base = String(withoutQuery[..<lastSlash])
                while base.hasSuffix("/") { base.removeLast() }
                return base
            }
        }
        return trimmed
    }

    public nonisolated static func manifestURL(forBase base: String) -> String {
        "\(normalizeBase(base))/manifest.json"
    }

    /// Canonical form for duplicate detection: lowercase scheme & host, omit default port, keep exact path case.
    public nonisolated static func canonicalURL(_ raw: String) -> String {
        let base = normalizeBase(raw)
        guard var comps = URLComponents(string: base),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(),
              !host.isEmpty else {
            return base
        }
        comps.scheme = scheme
        comps.host = host
        if (scheme == "https" && comps.port == 443) || (scheme == "http" && comps.port == 80) {
            comps.port = nil
        }
        while comps.path.hasSuffix("/") {
            comps.path.removeLast()
        }
        return comps.string ?? base
    }

    // MARK: Probing & Health

    public func probe(rawURL: String) async throws -> AddonProbeResult {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = parsed.host, !host.isEmpty else {
            throw AddonError.invalidURL
        }

        let base = Self.normalizeBase(trimmed)
        let isJSONDoc = parsed.path.lowercased().hasSuffix(".json")
        let candidates = isJSONDoc
            ? [trimmed, Self.manifestURL(forBase: base)]
            : [Self.manifestURL(forBase: base), trimmed]

        var firstReason: String?
        var lastError: Error?

        for attemptURL in candidates {
            do {
                let data = try await performGET(urlString: attemptURL)
                let manifest = try parseManifestPayload(data)
                if !manifest.isPlayable {
                    let declared = manifest.resources.joined(separator: ", ")
                    throw AddonError.notAnAddon("This addon declares \(declared). SoundChord needs search.")
                }
                manifestCache[base] = CacheEntry(value: manifest, expiresAt: Date().addingTimeInterval(Self.manifestTTL))
                let health: AddonHealthStatus = manifest.requiresBitChordAuth
                    ? .requiresAndroidAttestation
                    : .connected(version: manifest.version)
                return AddonProbeResult(
                    manifest: manifest,
                    baseURL: base,
                    manifestURL: attemptURL.lowercased().hasSuffix(".json") ? attemptURL : Self.manifestURL(forBase: base),
                    health: health,
                    hadManifest: true
                )
            } catch AddonError.requiresAndroidAttestation {
                throw AddonError.requiresAndroidAttestation
            } catch AddonError.notAnAddon(let reason) {
                if firstReason == nil { firstReason = reason }
            } catch {
                lastError = error
            }
        }

        // Pass 3: Behavioral fallback: probe `{base}/search?q=music` in case the addon publishes no manifest.
        if let searchURL = buildEndpointURL(base: base, pathSegments: ["search"], queryItems: [URLQueryItem(name: "q", value: "music")]) {
            do {
                let data = try await performGET(urlString: searchURL.absoluteString)
                let decoded = try JSONDecoder().decode(AddonSearchResponse.self, from: data)
                _ = decoded.tracks.count
                let synthesized = AddonManifest(
                    id: base,
                    name: URL(string: base)?.host ?? base,
                    version: "",
                    description: "Addon without manifest (search verified)",
                    resources: ["search", "stream"]
                )
                return AddonProbeResult(
                    manifest: synthesized,
                    baseURL: base,
                    manifestURL: Self.manifestURL(forBase: base),
                    health: .connected(version: ""),
                    hadManifest: false
                )
            } catch AddonError.requiresAndroidAttestation {
                throw AddonError.requiresAndroidAttestation
            } catch {
                // Fall through to report manifest error
            }
        }

        if let firstReason {
            throw AddonError.notAnAddon(firstReason)
        }
        if let addonErr = lastError as? AddonError {
            throw addonErr
        }
        throw AddonError.networkError(lastError?.localizedDescription ?? "Could not reach addon server.")
    }

    public func checkHealth(config: AddonConfig) async -> (AddonHealthStatus, AddonManifest?) {
        do {
            let result = try await probe(rawURL: config.manifestURL.isEmpty ? config.baseURL : config.manifestURL)
            return (result.health, result.manifest)
        } catch AddonError.requiresAndroidAttestation {
            return (.requiresAndroidAttestation, nil)
        } catch {
            return (.unreachable(error.localizedDescription), nil)
        }
    }

    // MARK: Search

    public func search(config: AddonConfig, query: String, quality: AudioQuality) async throws -> [AddonTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if config.requiresBitChordAuth {
            throw AddonError.requiresAndroidAttestation
        }

        let params = queryParams(for: config, quality: quality)
        let cacheKey = "\(config.baseURL)|\(trimmed)|\(params.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))"
        if let cached = searchCache[cacheKey], cached.expiresAt > Date() {
            return cached.value
        }

        var items = params
        items.append(URLQueryItem(name: "q", value: trimmed))

        guard let url = buildEndpointURL(base: config.baseURL, pathSegments: ["search"], queryItems: items) else {
            throw AddonError.invalidURL
        }

        let data = try await performGET(urlString: url.absoluteString)
        let decoded = try JSONDecoder().decode(AddonSearchResponse.self, from: data)
        let filtered = decoded.tracks.filter { !$0.id.isEmpty && !$0.title.isEmpty }
        searchCache[cacheKey] = CacheEntry(value: filtered, expiresAt: Date().addingTimeInterval(Self.searchTTL))
        return filtered
    }

    // MARK: Stream Resolution

    public func resolveStream(
        config: AddonConfig,
        trackId: String,
        quality: AudioQuality,
        fallbackStreamURL: String? = nil,
        durationHint: TimeInterval? = nil
    ) async throws -> ResolvedStream {
        if config.requiresBitChordAuth {
            throw AddonError.requiresAndroidAttestation
        }

        let params = queryParams(for: config, quality: quality)
        let cacheKey = "\(config.baseURL)|\(trackId)|\(params.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))"

        let addonStream: AddonStream
        if let cached = streamCache[cacheKey], cached.expiresAt > Date() {
            addonStream = cached.value
        } else {
            guard let url = buildEndpointURL(base: config.baseURL, pathSegments: ["stream", trackId], queryItems: params) else {
                throw AddonError.invalidURL
            }
            do {
                let data = try await performGET(urlString: url.absoluteString)
                let decoded = try JSONDecoder().decode(AddonStream.self, from: data)
                if decoded.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let fallback = fallbackStreamURL, !fallback.isEmpty {
                        addonStream = AddonStream(url: fallback)
                    } else {
                        throw AddonError.streamUnavailable(decoded.error ?? "Addon returned no stream URL for this track.")
                    }
                } else {
                    addonStream = decoded
                    streamCache[cacheKey] = CacheEntry(value: decoded, expiresAt: Date().addingTimeInterval(Self.streamTTL))
                }
            } catch {
                if let fallback = fallbackStreamURL, !fallback.isEmpty {
                    addonStream = AddonStream(url: fallback)
                } else {
                    throw error
                }
            }
        }

        return try makeResolvedStream(from: addonStream, config: config, durationHint: durationHint)
    }

    public func clearCaches(forBase baseURL: String? = nil) {
        if let baseURL {
            let norm = Self.normalizeBase(baseURL)
            manifestCache.removeValue(forKey: norm)
            searchCache = searchCache.filter { !$0.key.hasPrefix(norm) }
            streamCache = streamCache.filter { !$0.key.hasPrefix(norm) }
        } else {
            manifestCache.removeAll()
            searchCache.removeAll()
            streamCache.removeAll()
        }
    }

    // MARK: Private Helpers

    private func makeResolvedStream(from stream: AddonStream, config: AddonConfig, durationHint: TimeInterval?) throws -> ResolvedStream {
        let rawURL = stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              !Self.isMalformedDoubledOrigin(rawURL) else {
            throw AddonError.streamUnavailable("Addon returned an invalid stream URL.")
        }
        if stream.encrypted {
            throw AddonError.encryptedStreamUnsupported
        }
        if stream.transport == "dash" {
            throw AddonError.dashStreamUnsupported
        }

        let isHLS = stream.transport == "hls"
        let codec = stream.resolvedCodec
        let bitrateKbps = stream.normalizedBitrateKbps ?? (stream.isLossless ? 0 : 320)
        let sampleRateHz = stream.normalizedSampleRateHz ?? (stream.isLossless ? 44_100 : nil)
        let bitDepth = stream.normalizedBitDepth ?? (stream.isLossless ? 16 : nil)

        return ResolvedStream(
            url: url,
            mimeType: stream.resolvedMimeType,
            codec: codec,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            bitDepth: bitDepth,
            contentLength: nil,
            expiresAt: stream.resolvedExpiryDate,
            clientName: "ADDON:\(config.displayName)",
            qualityLabel: stream.resolvedQualityLabel,
            isHLS: isHLS,
            requestHeaders: [:],
            durationSeconds: durationHint.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private func queryParams(for config: AddonConfig, quality: AudioQuality) -> [URLQueryItem] {
        var dict = config.defaultSettings

        let tier: String
        switch quality {
        case .lossless: tier = "LOSSLESS"
        case .high: tier = "HIGH"
        case .medium, .low: tier = "LOW"
        }

        let optionValues = config.qualityOptions.map(\.value)
        let chosenQuality: String
        if quality == .lossless {
            if let picked = config.preferredQuality, optionValues.contains(picked) {
                chosenQuality = picked
            } else if let first = optionValues.first {
                chosenQuality = first
            } else if let picked = config.preferredQuality, !picked.isEmpty {
                chosenQuality = picked
            } else {
                chosenQuality = tier
            }
        } else {
            chosenQuality = matchLowerTier(tier: tier, options: optionValues) ?? tier
        }

        dict["quality"] = chosenQuality
        return dict.keys.sorted().map { URLQueryItem(name: $0, value: dict[$0]) }
    }

    private func matchLowerTier(tier: String, options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let exact = options.first(where: { $0.caseInsensitiveCompare(tier) == .orderedSame }) {
            return exact
        }
        let words = tier == "LOW" ? Self.lowQualityWords : Self.highQualityWords
        if let matched = options.first(where: { opt in
            let lowered = opt.lowercased()
            return words.contains(where: { lowered.contains($0) })
        }) {
            return matched
        }
        return options.first
    }

    private func buildEndpointURL(base: String, pathSegments: [String], queryItems: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: Self.normalizeBase(base)) else { return nil }
        var encodedPath = comps.percentEncodedPath
        while encodedPath.hasSuffix("/") { encodedPath.removeLast() }

        var segmentAllowed = CharacterSet.urlPathAllowed
        segmentAllowed.remove(charactersIn: "/?#")

        for segment in pathSegments {
            let encoded = segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
            encodedPath += "/\(encoded)"
        }
        comps.percentEncodedPath = encodedPath
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        return comps.url
    }

    private func performGET(urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw AddonError.invalidURL
        }
        let hostKey = url.host?.lowercased() ?? urlString
        var attempt = 0

        while true {
            if let quietUntil = quietUntilByHost[hostKey] {
                let waitSec = quietUntil.timeIntervalSinceNow
                if waitSec > 0 {
                    try await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                }
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw AddonError.networkError(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw AddonError.networkError("Invalid HTTP response.")
            }

            if (200..<300).contains(http.statusCode) {
                guard !data.isEmpty else {
                    throw AddonError.notAnAddon("Addon returned an empty response.")
                }
                return data
            }

            if http.statusCode == 401 {
                let wwwAuth = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
                if wwwAuth.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("bitchord") {
                    throw AddonError.requiresAndroidAttestation
                }
                throw AddonError.networkError("HTTP 401 Unauthorized")
            }

            if http.statusCode == 404 {
                throw AddonError.streamUnavailable("Not found (HTTP 404)")
            }

            if http.statusCode == 429 && attempt < Self.maxRateLimitRetries {
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After")
                let retrySec: TimeInterval
                if let retryHeader, let parsed = Double(retryHeader.trimmingCharacters(in: .whitespaces)) {
                    retrySec = min(Self.maxBackoffSec, max(0.5, parsed))
                } else {
                    retrySec = min(Self.maxBackoffSec, 0.5 * pow(2.0, Double(attempt)))
                }
                quietUntilByHost[hostKey] = Date().addingTimeInterval(retrySec)
                attempt += 1
                continue
            }

            if http.statusCode == 429 {
                throw AddonError.networkError("This addon is rate limiting requests (HTTP 429).")
            }

            throw AddonError.networkError("HTTP \(http.statusCode)")
        }
    }

    private func parseManifestPayload(_ data: Data) throws -> AddonManifest {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) else {
            throw AddonError.notAnAddon("That address did not return JSON.")
        }
        guard let dict = jsonObj as? [String: Any] else {
            throw AddonError.notAnAddon("Expected a JSON object for an addon manifest.")
        }
        if dict.keys.contains(where: { $0.hasPrefix("category:") }) {
            throw AddonError.notAnAddon("This URL is a legacy JS module index, not an HTTP BitChord addon manifest.")
        }
        let looksLikeManifest = (dict["resources"] is [Any]) ||
            (dict["id"] != nil && (dict["name"] != nil || dict["version"] != nil))
        guard looksLikeManifest else {
            throw AddonError.notAnAddon("That URL answered with JSON, but not a BitChord addon manifest.")
        }
        do {
            let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
            if manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AddonError.notAnAddon("Addon manifest is missing an id and name.")
            }
            return manifest
        } catch let err as AddonError {
            throw err
        } catch {
            throw AddonError.notAnAddon("Could not parse addon manifest: \(error.localizedDescription)")
        }
    }

    private static func isMalformedDoubledOrigin(_ url: String) -> Bool {
        guard let schemeRange = url.range(of: "://") else { return true }
        guard let pathSlash = url[schemeRange.upperBound...].firstIndex(of: "/") else { return false }
        let origin = String(url[..<pathSlash])
        return url[pathSlash...].contains(origin)
    }
}

// MARK: - AddonManager

@MainActor
public final class AddonManager: ObservableObject {
    @Published public private(set) var addons: [AddonConfig] = []
    @Published public private(set) var healthById: [String: AddonHealthStatus] = [:]
    @Published public private(set) var isRefreshingHealth: Bool = false

    public let client: AddonClient

    private let storageURL: URL
    private var cachedTracksByCompositeKey: [String: AddonTrack] = [:]
    private var cachedTrackKeysOrder: [String] = []
    private let maxCachedTracks = 256

    // MARK: Curated Live-Verified BitChord Addons Catalog

    public static let curatedCatalog: [CuratedAddonPreset] = [
        CuratedAddonPreset(
            id: "resonance-hifi",
            name: "Resonance (Qobuz Hi-Res + TIDAL)",
            subtitle: "24-bit up to 192 kHz Qobuz FLAC + TIDAL lossless, downloads allowed, no attestation needed.",
            manifestURL: "https://www.resonance.web.id/manifest.json",
            setupURL: "https://www.resonance.web.id",
            category: "Direct 1-Click Install",
            isDirectInstall: true,
            note: "Live-verified Hi-Res FLAC & Lossless (v3.0.0)"
        ),
        CuratedAddonPreset(
            id: "rezenonance-vercel",
            name: "ReZenOnance Qobuz (Vercel)",
            subtitle: "Direct Qobuz FLAC lossless catalog via Monochrome gateway, fast edge CDN.",
            manifestURL: "https://qobuz-addon.vercel.app/manifest.json",
            setupURL: "https://qobuz-addon.vercel.app",
            category: "Direct 1-Click Install",
            isDirectInstall: true,
            note: "Live-verified Lossless FLAC (playback only)"
        ),
        CuratedAddonPreset(
            id: "rezenonance-render",
            name: "ReZenOnance Qobuz (Render Mirror)",
            subtitle: "Backup mirror of ReZenOnance Qobuz FLAC addon hosted on Render.",
            manifestURL: "https://rezenonance.onrender.com/manifest.json",
            setupURL: "https://rezenonance.onrender.com",
            category: "Direct 1-Click Install",
            isDirectInstall: true,
            note: "Backup mirror for ReZenOnance Qobuz"
        ),
        CuratedAddonPreset(
            id: "tido-tidal",
            name: "Tido (Tidal Hi-Res + Atmos)",
            subtitle: "Direct Tidal Hi-Res 24-bit/192kHz FLAC, Dolby Atmos, and ArtistGrid unreleased music.",
            manifestURL: nil,
            setupURL: "https://tido.tido.tido.rickyaddons.dpdns.org/",
            category: "Setup Page / Token Generator",
            isDirectInstall: false,
            note: "Open setup page in browser, click \"Generate manifest link\", then paste your personal manifest URL above."
        ),
        CuratedAddonPreset(
            id: "bitchord-selfhosted",
            name: "BitChord Self-Hosted (Plex / Jellyfin / Emby / Navidrome)",
            subtitle: "Stream your own personal lossless music library from Plex, Jellyfin, Emby, or Navidrome.",
            manifestURL: nil,
            setupURL: "https://github.com/rairulyle/bitchord-selfhosted-addon",
            category: "Self-Hosted & Docs",
            isDirectInstall: false,
            note: "Deploy via Docker, configure at /setup, then paste each server's /manifest.json URL above."
        ),
        CuratedAddonPreset(
            id: "bitchord-official-docs",
            name: "Official BitChord Addon Docs",
            subtitle: "Developer specification for building custom BitChord HTTP addons (manifest, search, stream, quality).",
            manifestURL: nil,
            setupURL: "https://bitchord.kushagrasingh.in/docs",
            category: "Self-Hosted & Docs",
            isDirectInstall: false,
            note: "Official protocol reference by kushagrasinghx"
        )
    ]

    // MARK: Initialization

    public init(baseDirectory: URL? = nil, client: AddonClient = AddonClient()) {
        self.client = client
        let fm = FileManager.default
        let dir: URL
        if let baseDirectory {
            dir = baseDirectory
        } else {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            dir = appSupport.appendingPathComponent("SoundChord", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = dir.appendingPathComponent("addons.json", isDirectory: false)
        if baseDirectory == nil {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let legacyAddons = appSupport
                .appendingPathComponent("BitChord", isDirectory: true)
                .appendingPathComponent("addons.json", isDirectory: false)
            if !fm.fileExists(atPath: storage.path), fm.fileExists(atPath: legacyAddons.path) {
                try? fm.copyItem(at: legacyAddons, to: storage)
            }
        }
        self.storageURL = storage
        loadFromDisk()
    }

    // MARK: Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([AddonConfig].self, from: data) else {
            addons = []
            return
        }
        addons = decoded
        for addon in addons where healthById[addon.id] == nil {
            healthById[addon.id] = addon.requiresBitChordAuth ? .requiresAndroidAttestation : .unknown
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(addons) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    // MARK: CRUD & Priority Management

    public func isInstalled(manifestOrBaseURL: String) -> Bool {
        let target = AddonClient.canonicalURL(manifestOrBaseURL)
        return addons.contains { AddonClient.canonicalURL($0.baseURL) == target }
    }

    public func testAddonURL(_ rawURL: String) async throws -> AddonProbeResult {
        try await client.probe(rawURL: rawURL)
    }

    @discardableResult
    public func addAddon(from rawURL: String, preferredQuality: String? = nil) async throws -> AddonConfig {
        let probed = try await client.probe(rawURL: rawURL)
        let targetCanonical = AddonClient.canonicalURL(probed.baseURL)
        if let existing = addons.first(where: { AddonClient.canonicalURL($0.baseURL) == targetCanonical }) {
            throw AddonError.duplicateAddon(existing.displayName)
        }

        let options = probed.manifest.qualityOptions
        let resolvedPreferred: String?
        if let preferredQuality, options.contains(where: { $0.value == preferredQuality }) {
            resolvedPreferred = preferredQuality
        } else {
            resolvedPreferred = options.first?.value
        }

        let config = AddonConfig(
            name: probed.manifest.displayName,
            baseURL: probed.baseURL,
            manifestURL: probed.manifestURL,
            isEnabled: true,
            preferredQuality: resolvedPreferred,
            allowDownloads: probed.manifest.allowDownloads,
            checkValidLossless: probed.manifest.checkValidLossless,
            requiresBitChordAuth: probed.manifest.requiresBitChordAuth,
            version: probed.manifest.version,
            iconURL: probed.manifest.icon,
            description: probed.manifest.description,
            qualityOptions: options,
            defaultSettings: probed.manifest.defaultSettingsMap
        )

        addons.append(config)
        healthById[config.id] = probed.health
        saveToDisk()
        return config
    }

    public func removeAddon(id: String) {
        if let removed = addons.first(where: { $0.id == id }) {
            Task { await client.clearCaches(forBase: removed.baseURL) }
        }
        addons.removeAll { $0.id == id }
        healthById.removeValue(forKey: id)
        saveToDisk()
    }

    public func toggleAddon(id: String) {
        guard let idx = addons.firstIndex(where: { $0.id == id }) else { return }
        addons[idx].isEnabled.toggle()
        saveToDisk()
    }

    public func moveAddon(id: String, direction: AddonMoveDirection) {
        guard let idx = addons.firstIndex(where: { $0.id == id }) else { return }
        let target: Int
        switch direction {
        case .up:
            guard idx > 0 else { return }
            target = idx - 1
        case .down:
            guard idx + 1 < addons.count else { return }
            target = idx + 1
        }
        addons.swapAt(idx, target)
        saveToDisk()
    }

    public func updatePreferredQuality(id: String, quality: String?) {
        guard let idx = addons.firstIndex(where: { $0.id == id }) else { return }
        addons[idx].preferredQuality = quality
        let baseURL = addons[idx].baseURL
        saveToDisk()
        Task { await client.clearCaches(forBase: baseURL) }
    }

    public func refreshAllHealth() async {
        guard !addons.isEmpty else { return }
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }

        let snapshot = addons
        for config in snapshot {
            healthById[config.id] = .checking
        }

        await withTaskGroup(of: (String, AddonHealthStatus, AddonManifest?).self) { group in
            for config in snapshot {
                let clientRef = self.client
                group.addTask {
                    let (status, manifest) = await clientRef.checkHealth(config: config)
                    return (config.id, status, manifest)
                }
            }
            for await (id, status, manifest) in group {
                healthById[id] = status
                if let manifest, let idx = addons.firstIndex(where: { $0.id == id }) {
                    var updated = addons[idx]
                    if !manifest.displayName.isEmpty { updated.name = manifest.displayName }
                    if !manifest.version.isEmpty { updated.version = manifest.version }
                    if !manifest.description.isEmpty { updated.description = manifest.description }
                    if let icon = manifest.icon, !icon.isEmpty { updated.iconURL = icon }
                    updated.allowDownloads = manifest.allowDownloads
                    updated.checkValidLossless = manifest.checkValidLossless
                    updated.requiresBitChordAuth = manifest.requiresBitChordAuth
                    let newOptions = manifest.qualityOptions
                    updated.qualityOptions = newOptions
                    updated.defaultSettings = manifest.defaultSettingsMap
                    if let picked = updated.preferredQuality, !newOptions.isEmpty,
                       !newOptions.contains(where: { $0.value == picked }) {
                        updated.preferredQuality = newOptions.first?.value
                    }
                    addons[idx] = updated
                }
            }
        }
        saveToDisk()
    }

    // MARK: Search Across Enabled Addons

    public func searchAddons(query: String, quality: AudioQuality) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let enabled = addons.filter { $0.isEnabled && !$0.requiresBitChordAuth }
        guard !enabled.isEmpty else { return [] }

        let clientRef = self.client
        let perAddon: [(Int, AddonConfig, [AddonTrack])] = await withTaskGroup(of: (Int, AddonConfig, [AddonTrack]).self) { group in
            for (index, config) in enabled.enumerated() {
                group.addTask {
                    let tracks = (try? await clientRef.search(config: config, query: trimmed, quality: quality)) ?? []
                    return (index, config, Array(tracks.prefix(25)))
                }
            }
            var collected: [(Int, AddonConfig, [AddonTrack])] = []
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        // Convert to Track lists and cache raw AddonTracks for stream fallback/duration metadata.
        var trackBuckets: [[Track]] = []
        for (_, config, rawTracks) in perAddon {
            var bucket: [Track] = []
            for raw in rawTracks {
                cacheAddonTrack(raw, configId: config.id)
                let packedId = "src:\(config.id)::\(raw.id)"
                let track = Track(
                    id: packedId,
                    videoId: packedId,
                    title: raw.title,
                    artist: raw.artist.isEmpty ? config.displayName : raw.artist,
                    album: raw.album.isEmpty ? nil : raw.album,
                    duration: raw.durationSeconds,
                    artworkURL: raw.resolvedArtworkURL,
                    qualityLabel: raw.formattedQualityBadge,
                    audioCodec: raw.inferredCodec,
                    sampleRateHz: raw.normalizedSampleRateHz,
                    bitDepth: raw.bitDepth,
                    addonConfigId: config.id,
                    addonTrackId: raw.id,
                    sourceName: config.displayName
                )
                bucket.append(track)
            }
            if !bucket.isEmpty {
                trackBuckets.append(bucket)
            }
        }

        // Round-robin interleave so no single addon buries the rest.
        let maxLen = trackBuckets.map(\.count).max() ?? 0
        var merged: [Track] = []
        for i in 0..<maxLen {
            for bucket in trackBuckets where i < bucket.count {
                merged.append(bucket[i])
            }
        }
        return merged
    }

    // MARK: Direct Addon Stream Resolution

    public func resolveDirectAddonStream(
        configId: String,
        addonTrackId: String,
        quality: AudioQuality
    ) async throws -> ResolvedStream {
        guard let config = addons.first(where: { $0.id == configId }) else {
            throw AddonError.addonNotFound
        }
        let cached = cachedTracksByCompositeKey["\(configId)::\(addonTrackId)"]
        return try await client.resolveStream(
            config: config,
            trackId: addonTrackId,
            quality: quality,
            fallbackStreamURL: cached?.streamURL,
            durationHint: cached.map(\.durationSeconds)
        )
    }

    // MARK: Automatic Lossless Substitution for YouTube Tracks

    public func resolveLosslessSubstitute(
        for track: Track,
        quality: AudioQuality,
        durationToleranceSec: Double
    ) async -> ResolvedStream? {
        guard quality == .lossless else { return nil }
        let enabled = addons.filter { $0.isEnabled && !$0.requiresBitChordAuth }
        guard !enabled.isEmpty else { return nil }

        let queries = TrackMatcher.queries(for: track)
        guard !queries.isEmpty else { return nil }

        let clientRef = self.client

        // Query all enabled addons in parallel, then evaluate winners strictly in priority order.
        let resultsByIndex: [(Int, ResolvedStream?)] = await withTaskGroup(of: (Int, ResolvedStream?).self) { group in
            for (index, config) in enabled.enumerated() {
                group.addTask {
                    var collected: [AddonTrack] = []
                    for q in queries {
                        if let found = try? await clientRef.search(config: config, query: q, quality: quality), !found.isEmpty {
                            collected.append(contentsOf: found)
                            let rankedNow = TrackMatcher.ranked(
                                candidates: collected,
                                target: track,
                                durationToleranceSec: durationToleranceSec
                            )
                            if !rankedNow.isEmpty {
                                break
                            }
                        }
                    }

                    let ranked = TrackMatcher.ranked(
                        candidates: collected,
                        target: track,
                        durationToleranceSec: durationToleranceSec
                    )
                    guard !ranked.isEmpty else { return (index, nil) }

                    // Try top 3 matched candidates (skips DASH or unavailable tracks gracefully).
                    for candidate in ranked.prefix(3) {
                        if let resolved = try? await clientRef.resolveStream(
                            config: config,
                            trackId: candidate.id,
                            quality: quality,
                            fallbackStreamURL: candidate.streamURL,
                            durationHint: candidate.durationSeconds > 0 ? candidate.durationSeconds : (track.duration > 0 ? track.duration : nil)
                        ) {
                            // Only substitute if lossless (FLAC/ALAC/WAV/AIFF) or high-bitrate upgrade (>= 256 kbps).
                            let codecLower = resolved.codec.lowercased()
                            let isLossless = ["flac", "alac", "wav", "aiff"].contains(codecLower)
                            if isLossless || resolved.bitrateKbps >= 256 {
                                return (index, resolved)
                            }
                        }
                    }
                    return (index, nil)
                }
            }

            var out: [(Int, ResolvedStream?)] = []
            for await item in group {
                out.append(item)
            }
            return out.sorted { $0.0 < $1.0 }
        }

        // First priority-ordered lossless hit wins; otherwise first high-bitrate hit.
        for (_, stream) in resultsByIndex {
            if let stream, ["flac", "alac", "wav", "aiff"].contains(stream.codec.lowercased()) {
                return stream
            }
        }
        return resultsByIndex.compactMap(\.1).first
    }

    // MARK: Track Row Cache

    private func cacheAddonTrack(_ track: AddonTrack, configId: String) {
        let key = "\(configId)::\(track.id)"
        if cachedTracksByCompositeKey[key] == nil {
            cachedTrackKeysOrder.append(key)
        }
        cachedTracksByCompositeKey[key] = track
        while cachedTrackKeysOrder.count > maxCachedTracks {
            let oldest = cachedTrackKeysOrder.removeFirst()
            cachedTracksByCompositeKey.removeValue(forKey: oldest)
        }
    }
}
