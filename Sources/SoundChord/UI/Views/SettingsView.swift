import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case audio = "Audio & EQ"
        case appearance = "Appearance"
        case lyrics = "Lyrics"
        case discord = "Discord"
        case account = "Account"
        case storage = "Storage & About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .audio: return "slider.vertical.3"
            case .appearance: return "paintbrush.fill"
            case .lyrics: return "quote.bubble.fill"
            case .discord: return "bubble.left.and.bubble.right.fill"
            case .account: return "person.crop.circle.fill"
            case .storage: return "externaldrive.fill"
            }
        }
    }

    @State private var selectedCategory: SettingsCategory = .audio
    @State private var cookieDraft: String = ""
    @State private var revealCookieText: Bool = false
    @State private var isReconnectingDiscord: Bool = false
    @State private var isClearingCache: Bool = false

    @AppStorage("soundchord.defaultTranslationLanguage")
    private var defaultTranslationLanguage: String = "en"

    private static let translationLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("hi", "Hindi"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("vi", "Vietnamese"),
        ("th", "Thai")
    ]

    private var settings: AppSettings {
        appState.libraryStore.settings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREFERENCES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        .tracking(0.8)
                    Text("Settings")
                        .font(.system(size: 34, weight: .bold))
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                // Segmented Category Tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SettingsCategory.allCases) { category in
                            let selected = selectedCategory == category
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    selectedCategory = category
                                }
                            } label: {
                                Label(category.rawValue, systemImage: category.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(
                                        selected
                                            ? SoundChordTheme.accentForeground(for: colorScheme)
                                            : SoundChordTheme.primaryText(for: colorScheme)
                                    )
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                selected
                                                    ? SoundChordTheme.accentColor(for: colorScheme)
                                                    : SoundChordTheme.cardBackground(for: colorScheme)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 36)
                }

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                // Active Section Content
                Group {
                    switch selectedCategory {
                    case .audio:
                        audioAndEQSection
                    case .appearance:
                        appearanceSection
                    case .lyrics:
                        lyricsSection
                    case .discord:
                        discordSection
                    case .account:
                        youtubeAccountSection
                    case .storage:
                        storageAndAboutSection
                    }
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .padding(.bottom, 110)
        }
        .onAppear {
            cookieDraft = settings.ytCookieHeader
        }
    }

    // MARK: - 1. Audio & Equalizer

    private var audioAndEQSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Audio Quality & Playback Card
            SettingsCard(title: "Audio Quality & Playback", icon: "hifispeaker.2.fill") {
                VStack(alignment: .leading, spacing: 16) {
                    // Stream Quality
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Streaming Quality")
                                .font(.system(size: 13, weight: .semibold))
                            Text(settings.streamQuality.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.streamQuality },
                            set: { quality in
                                appState.updateSettings { $0.streamQuality = quality }
                            }
                        )) {
                            ForEach(AudioQuality.allCases) { q in
                                Text(q.displayName).tag(q)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    // Download Quality
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download Quality")
                                .font(.system(size: 13, weight: .semibold))
                            Text(settings.downloadQuality.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.downloadQuality },
                            set: { quality in
                                appState.updateSettings { $0.downloadQuality = quality }
                            }
                        )) {
                            ForEach(AudioQuality.allCases) { q in
                                Text(q.displayName).tag(q)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    // Crossfade Slider (0-12s)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Crossfade")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(settings.crossfadeSeconds == 0 ? "Off" : String(format: "%.1f s", settings.crossfadeSeconds))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(settings.crossfadeSeconds > 0 ? SoundChordTheme.accentColor(for: colorScheme) : SoundChordTheme.secondaryText(for: colorScheme))
                        }
                        Slider(
                            value: Binding(
                                get: { settings.crossfadeSeconds },
                                set: { val in
                                    appState.updateSettings { $0.crossfadeSeconds = val }
                                }
                            ),
                            in: 0...12,
                            step: 0.5
                        )
                        .tint(SoundChordTheme.accentColor(for: colorScheme))
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    // Playback Speed (0.5x-2.0x)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Playback Speed")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if abs(settings.playbackSpeed - 1.0) > 0.01 {
                                Button("Reset 1.0x") {
                                    appState.updateSettings { $0.playbackSpeed = 1.0 }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            }
                            Text(String(format: "%.2fx", settings.playbackSpeed))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.playbackSpeed) },
                                set: { val in
                                    appState.updateSettings { $0.playbackSpeed = Float(val) }
                                }
                            ),
                            in: 0.5...2.0,
                            step: 0.05
                        )
                        .tint(SoundChordTheme.accentColor(for: colorScheme))
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    // Loudness Normalization Toggle
                    Toggle(isOn: Binding(
                        get: { settings.loudnessNormalization },
                        set: { enabled in
                            appState.updateSettings { $0.loudnessNormalization = enabled }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loudness Normalization")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Maintain consistent perceived volume across tracks")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(SoundChordTheme.accentColor(for: colorScheme))

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    // Stereo L/R Balance
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Stereo Balance")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if abs(settings.balance) > 0.02 {
                                Button("Center") {
                                    appState.updateSettings { $0.balance = 0 }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            }
                            Text(balanceLabel(settings.balance))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Text("L")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(settings.balance) },
                                    set: { val in
                                        appState.updateSettings { $0.balance = Float(val) }
                                    }
                                ),
                                in: -1.0...1.0
                            )
                            .tint(SoundChordTheme.accentColor(for: colorScheme))
                            Text("R")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Addons & Sources Card
            SettingsCard(title: "Addons & Sources", icon: "puzzlepiece.extension.fill") {
                let totalCount = appState.addonManager.addons.count
                let enabledCount = appState.addonManager.addons.filter(\.isEnabled).count

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BitChord HTTP Addons")
                                .font(.system(size: 13, weight: .semibold))
                            Text(totalCount == 0
                                 ? "No addons configured yet · Install Resonance or Qobuz for Hi-Res FLAC"
                                 : "\(enabledCount) of \(totalCount) addon\(totalCount == 1 ? "" : "s") active")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.selectSidebar(.addons)
                        } label: {
                            HStack(spacing: 5) {
                                Text("Manage Addons")
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    Toggle(isOn: Binding(
                        get: { settings.addonLosslessUpgrade },
                        set: { enabled in
                            appState.updateSettings { $0.addonLosslessUpgrade = enabled }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic Lossless Upgrade")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Match YouTube Music tracks against enabled addons for Lossless FLAC when Streaming Quality is Lossless")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(SoundChordTheme.accentColor(for: colorScheme))
                }
            }

            // 7-Band Graphic Equalizer Card
            SettingsCard(title: "7-Band Graphic Equalizer", icon: "waveform") {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Toggle("Enable Equalizer", isOn: Binding(
                            get: { settings.eqEnabled },
                            set: { enabled in
                                appState.updateSettings { $0.eqEnabled = enabled }
                            }
                        ))
                        .toggleStyle(.switch)
                        .tint(SoundChordTheme.accentColor(for: colorScheme))

                        Spacer()

                        Picker("Preset", selection: Binding(
                            get: { settings.eqPreset },
                            set: { preset in
                                appState.updateSettings { s in
                                    s.eqPreset = preset
                                    if preset != .custom {
                                        s.eqGains = preset.gains
                                    }
                                    s.eqEnabled = true
                                }
                            }
                        )) {
                            ForEach(EQPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)

                        Button("Reset Flat") {
                            appState.updateSettings { s in
                                s.eqPreset = .flat
                                s.eqGains = EQPreset.flat.gains
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // 7 Interactive Vertical Sliders (60Hz–15kHz, -12dB...+12dB)
                    HStack(spacing: 0) {
                        // dB Scale Legend
                        VStack {
                            Text("+12 dB")
                            Spacer()
                            Text("0 dB")
                            Spacer()
                            Text("-12 dB")
                        }
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 170)
                        .padding(.bottom, 22)

                        ForEach(0..<EQBand.defaultFrequencies.count, id: \.self) { index in
                            let gain = index < settings.eqGains.count ? settings.eqGains[index] : 0
                            EQVerticalBandSlider(
                                label: EQBand.defaultLabels[index],
                                gainDb: Binding(
                                    get: { gain },
                                    set: { newValue in
                                        appState.updateSettings { s in
                                            var gains = s.eqGains
                                            if gains.count != EQBand.defaultFrequencies.count {
                                                gains = EQPreset.flat.gains
                                            }
                                            gains[index] = newValue
                                            s.eqGains = gains
                                            s.eqPreset = EQPreset.matching(gains: gains)
                                            s.eqEnabled = true
                                        }
                                    }
                                ),
                                isEnabled: settings.eqEnabled
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .opacity(settings.eqEnabled ? 1.0 : 0.55)
                }
            }
        }
    }

    // MARK: - 2. Appearance

    private var appearanceSection: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return SettingsCard(title: "Theme & Appearance", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme Switcher")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(primary)
                        Text("Choose System, Apple Music Light, or Spotify Dark in one click")
                            .font(.system(size: 12))
                            .foregroundStyle(secondary)
                    }

                    HStack(spacing: 12) {
                        themePresetCard(
                            mode: .system,
                            title: "System",
                            subtitle: "Match macOS",
                            leftSwatch: SoundChordTheme.lightBackground,
                            rightSwatch: SoundChordTheme.darkBackground,
                            accentDot: accent
                        )
                        themePresetCard(
                            mode: .light,
                            title: "Apple Music",
                            subtitle: "Crisp Light",
                            leftSwatch: SoundChordTheme.lightBackground,
                            rightSwatch: SoundChordTheme.lightSurface,
                            accentDot: SoundChordTheme.lightAccent
                        )
                        themePresetCard(
                            mode: .dark,
                            title: "Spotify",
                            subtitle: "OLED Dark",
                            leftSwatch: SoundChordTheme.darkOuterFrame,
                            rightSwatch: SoundChordTheme.darkBackground,
                            accentDot: SoundChordTheme.darkAccent
                        )
                    }
                }

                Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Light Mode Glass Opacity")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(primary)
                            Text("Controls translucency on the Light Mode sidebar and floating player capsule")
                                .font(.system(size: 12))
                                .foregroundStyle(secondary)
                        }
                        Spacer()
                        Text("\(Int((settings.glassOpacity * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(accent)
                    }

                    Slider(
                        value: Binding(
                            get: { settings.glassOpacity },
                            set: { val in
                                appState.updateSettings { $0.glassOpacity = val }
                            }
                        ),
                        in: 0.30...1.0,
                        step: 0.02
                    )
                    .tint(accent)
                }
            }
        }
    }

    private func themePresetCard(
        mode: ThemeMode,
        title: String,
        subtitle: String,
        leftSwatch: Color,
        rightSwatch: Color,
        accentDot: Color
    ) -> some View {
        let isSelected = settings.themeMode == mode
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return Button {
            appState.updateSettings { $0.themeMode = mode }
            appState.showToast("Theme set to \(title)")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    leftSwatch
                    rightSwatch
                }
                .frame(height: 36)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(accentDot)
                        .frame(width: 10, height: 10)
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
                )

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(primary)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(accent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(SoundChordTheme.elevatedBackground(for: colorScheme).opacity(isSelected ? 1.0 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .strokeBorder(isSelected ? accent : SoundChordTheme.hairline(for: colorScheme), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. Lyrics

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Translation", icon: "translate") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Translation Language")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Used when translating synced lyrics in the drawer or Full-Screen player")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $defaultTranslationLanguage) {
                        ForEach(Self.translationLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
            }

            SettingsCard(title: "Lyrics Provider Priority", icon: "list.number") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Higher providers are preferred when multiple word-synced or line-synced sources match.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Default Order") {
                            appState.updateSettings { $0.lyricsProvidersOrder = AppSettings.defaultLyricsProviders }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    let orderedAll = allProvidersOrdered()
                    VStack(spacing: 6) {
                        ForEach(Array(orderedAll.enumerated()), id: \.element) { index, provider in
                            let isEnabled = settings.lyricsProvidersOrder.contains(provider)
                            let enabledIndex = settings.lyricsProvidersOrder.firstIndex(of: provider)

                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                Toggle("", isOn: Binding(
                                    get: { isEnabled },
                                    set: { on in
                                        toggleLyricsProvider(provider, enabled: on)
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .tint(SoundChordTheme.accentColor(for: colorScheme))

                                Text(provider)
                                    .font(.system(size: 13, weight: isEnabled ? .semibold : .regular))
                                    .foregroundStyle(isEnabled ? .primary : .secondary)

                                Spacer()

                                if let pos = enabledIndex {
                                    HStack(spacing: 4) {
                                        Button {
                                            moveLyricsProvider(at: pos, direction: -1)
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .disabled(pos == 0)

                                        Button {
                                            moveLyricsProvider(at: pos, direction: 1)
                                        } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .disabled(pos >= settings.lyricsProvidersOrder.count - 1)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. Discord Rich Presence

    private var discordSection: some View {
        SettingsCard(title: "Discord Rich Presence", icon: "bubble.left.and.bubble.right.fill") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection Status")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Connects natively to local Discord desktop IPC socket")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle()
                            .fill(appState.isDiscordConnected ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text(appState.isDiscordConnected ? "Connected" : "Disconnected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(appState.isDiscordConnected ? .green : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            appState.isDiscordConnected
                                ? Color.green.opacity(0.14)
                                : Color.primary.opacity(0.07)
                        )
                    )
                }

                Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                Toggle(isOn: Binding(
                    get: { settings.discordRPCEnabled },
                    set: { enabled in
                        appState.updateSettings { $0.discordRPCEnabled = enabled }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Discord Rich Presence")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Share your currently playing track, album artwork, and progress")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(SoundChordTheme.accentColor(for: colorScheme))

                Toggle(isOn: Binding(
                    get: { settings.discordShowButtons },
                    set: { show in
                        appState.updateSettings { $0.discordShowButtons = show }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Action Buttons")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Include \"Listen on YouTube Music\" button in your Discord status")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(SoundChordTheme.accentColor(for: colorScheme))
                .disabled(!settings.discordRPCEnabled)

                HStack {
                    Button {
                        reconnectDiscord()
                    } label: {
                        HStack(spacing: 6) {
                            if isReconnectingDiscord {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Reconnect to Discord")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.discordRPCEnabled || isReconnectingDiscord)

                    Spacer()
                }
            }
        }
    }

    // MARK: - 5. YouTube Music Account

    private var youtubeAccountSection: some View {
        SettingsCard(title: "YouTube Music Account (Optional)", icon: "person.crop.circle.badge.checkmark") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(settings.ytCookieHeader.isEmpty ? "Signed Out (Guest Mode)" : "Cookie Configured")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(settings.ytCookieHeader.isEmpty ? Color.secondary : Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                settings.ytCookieHeader.isEmpty
                                    ? Color.primary.opacity(0.08)
                                    : Color.green.opacity(0.15)
                            )
                        )
                    Spacer()
                    Toggle("Show cookie text", isOn: $revealCookieText)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }

                Text("Paste your `Cookie` request header from `music.youtube.com` (open DevTools → Network → any `youtubei/v1/browse` request → Request Headers → `cookie`) to unlock personalized Home recommendations and private playlists. Stored locally on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)

                if revealCookieText {
                    TextEditor(text: $cookieDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 92)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
                        )
                } else {
                    SecureField("SAPISID=...; __Secure-3PAPISID=...; ...", text: $cookieDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(spacing: 10) {
                    Button {
                        let cleaned = cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.updateSettings { $0.ytCookieHeader = cleaned }
                        appState.showToast("Saved YouTube Music cookie, refreshing Home...")
                        Task { await appState.loadHome(force: true) }
                    } label: {
                        Text("Save & Refresh Home")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                    }
                    .buttonStyle(.plain)
                    .disabled(cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !settings.ytCookieHeader.isEmpty {
                        Button(role: .destructive) {
                            cookieDraft = ""
                            appState.updateSettings { $0.ytCookieHeader = "" }
                            appState.showToast("Signed out of YouTube Music")
                            Task { await appState.loadHome(force: true) }
                        } label: {
                            Text("Sign Out")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - 6. Storage & About

    private var storageAndAboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Storage, Cache & Backup", icon: "externaldrive.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backup & Restore Library")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Export or import Liked Songs, Playlists, History, and Settings as JSON")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Export Backup…") {
                                exportBackup()
                            }
                            .buttonStyle(.bordered)

                            Button("Import Backup…") {
                                importBackup()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stream URL Cache")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Clear cached resolved audio stream URLs if playback stalls")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            isClearingCache = true
                            Task {
                                defer { isClearingCache = false }
                                await appState.streamResolver.clearCache()
                                appState.showToast("Cleared stream cache")
                            }
                        } label: {
                            Text(isClearingCache ? "Clearing…" : "Clear Stream Cache")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearingCache)
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloads Folder")
                                .font(.system(size: 13, weight: .semibold))
                            Text("~/Library/Application Support/SoundChord/Downloads")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        }
                        Spacer()
                        Button("Reveal in Finder") {
                            revealDownloadsFolder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard(title: "About SoundChord for macOS", icon: "music.note.house.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: colorScheme == .dark
                                            ? [SoundChordTheme.darkAccent, SoundChordTheme.darkAccent.opacity(0.82)]
                                            : [SoundChordTheme.lightVibrantAccent, SoundChordTheme.lightAccent],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 48, height: 48)
                            Image(systemName: "waveform")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SoundChord for macOS")
                                .font(.system(size: 16, weight: .bold))
                            Text("Version 2.0.0 · Native SwiftUI, AVFoundation & Rust DSP")
                                .font(.system(size: 12))
                                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        }
                    }

                    Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                    Text("Licensed under the GNU General Public License v3.0 (GPLv3). You are free to study, modify, and redistribute this software under the terms of the GPLv3.")
                        .font(.system(size: 12))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))

                    HStack(spacing: 6) {
                        Text("Upstream attribution:")
                            .font(.system(size: 12, weight: .semibold))
                        if let url = URL(string: "https://github.com/kushagrasinghx/BitChord") {
                            Link("kushagrasinghx/BitChord", destination: url)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        } else {
                            Text("kushagrasinghx/BitChord")
                                .font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func balanceLabel(_ value: Float) -> String {
        if abs(value) < 0.03 { return "Center" }
        let pct = Int((abs(value) * 100).rounded())
        return value < 0 ? "\(pct)% Left" : "\(pct)% Right"
    }

    private func allProvidersOrdered() -> [String] {
        let enabled = settings.lyricsProvidersOrder
        let disabled = AppSettings.defaultLyricsProviders.filter { !enabled.contains($0) }
        return enabled + disabled
    }

    private func toggleLyricsProvider(_ provider: String, enabled: Bool) {
        appState.updateSettings { s in
            if enabled {
                if !s.lyricsProvidersOrder.contains(provider) {
                    s.lyricsProvidersOrder.append(provider)
                }
            } else {
                s.lyricsProvidersOrder.removeAll { $0 == provider }
            }
        }
    }

    private func moveLyricsProvider(at index: Int, direction: Int) {
        appState.updateSettings { s in
            let target = index + direction
            guard index >= 0, index < s.lyricsProvidersOrder.count,
                  target >= 0, target < s.lyricsProvidersOrder.count else { return }
            s.lyricsProvidersOrder.swapAt(index, target)
        }
    }

    private func reconnectDiscord() {
        isReconnectingDiscord = true
        Task {
            defer { isReconnectingDiscord = false }
            await appState.discordRPC.disconnect()
            await appState.discordRPC.connect()
            let connected = await appState.discordRPC.isConnected
            appState.isDiscordConnected = connected
            appState.showToast(connected ? "Connected to Discord" : "Discord desktop app not detected")
        }
    }

    private func exportBackup() {
        do {
            let data = try appState.libraryStore.exportBackupJSON()
            let panel = NSSavePanel()
            panel.title = "Export SoundChord Backup"
            panel.nameFieldStringValue = "SoundChord-Backup.json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                appState.showToast("Exported backup to \(url.lastPathComponent)")
            }
        } catch {
            appState.showError("Export failed: \(error.localizedDescription)")
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import SoundChord Backup"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try appState.libraryStore.importBackupJSON(data)
                cookieDraft = appState.libraryStore.settings.ytCookieHeader
                appState.showToast("Imported backup from \(url.lastPathComponent)")
            } catch {
                appState.showError("Import failed: \(error.localizedDescription)")
            }
        }
    }

    private func revealDownloadsFolder() {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let downloadsDir = appSupport
                .appendingPathComponent("SoundChord", isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
            try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([downloadsDir])
        }
    }
}

// MARK: - Settings Card Container

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
    }
}

// MARK: - Interactive Vertical EQ Band Slider (-12dB ... +12dB)

private struct EQVerticalBandSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    @Binding var gainDb: Float
    let isEnabled: Bool

    private let trackHeight: CGFloat = 156

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return VStack(spacing: 8) {
            Text(String(format: "%+.1f", gainDb))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(abs(gainDb) > 0.1 && isEnabled ? accent : secondary)
                .frame(height: 14)

            GeometryReader { geo in
                let height = geo.size.height
                let normalized = CGFloat((gainDb + 12.0) / 24.0) // 0 bottom (-12), 1 top (+12)
                let thumbY = height * (1.0 - normalized)
                let midY = height * 0.5

                ZStack {
                    // Track rail
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 5, height: height)

                    // Center 0 dB tick mark
                    Rectangle()
                        .fill(Color.primary.opacity(0.28))
                        .frame(width: 14, height: 1)
                        .position(x: geo.size.width / 2, y: midY)

                    // Active fill from 0 dB to thumb
                    let fillHeight = abs(thumbY - midY)
                    let fillCenterY = (thumbY + midY) / 2
                    Capsule()
                        .fill(isEnabled ? accent : secondary)
                        .frame(width: 5, height: max(2, fillHeight))
                        .position(x: geo.size.width / 2, y: fillCenterY)

                    // Draggable Thumb Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .overlay(
                            Circle()
                                .strokeBorder(isEnabled ? accent : secondary, lineWidth: 2)
                        )
                        .position(x: geo.size.width / 2, y: max(8, min(height - 8, thumbY)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedY = max(0, min(height, value.location.y))
                            let ratio = 1.0 - (clampedY / height)
                            let db = Float(ratio * 24.0 - 12.0)
                            let snapped = (db * 2).rounded() / 2 // 0.5 dB steps
                            gainDb = max(-12, min(12, snapped))
                        }
                )
            }
            .frame(width: 36, height: trackHeight)

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
