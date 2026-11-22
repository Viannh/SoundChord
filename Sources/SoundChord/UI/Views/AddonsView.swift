import AppKit
import SwiftUI

public struct AddonsView: View {
    @ObservedObject var addonManager: AddonManager
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var urlDraft: String = ""
    @State private var isTestingURL: Bool = false
    @State private var isAddingURL: Bool = false
    @State private var probePreview: AddonProbeResult?
    @State private var urlError: String?
    @State private var installingPresetIds: Set<String> = []

    public init(addonManager: AddonManager) {
        self.addonManager = addonManager
    }

    private var settings: AppSettings {
        appState.libraryStore.settings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                Divider()
                    .overlay(SoundChordTheme.hairline(for: colorScheme))
                    .padding(.horizontal, 36)

                VStack(alignment: .leading, spacing: 22) {
                    addCustomAddonCard
                    installedSourcesCard
                    losslessUpgradeCard
                    curatedDirectoryCard
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: 920, alignment: .leading)
            }
            .padding(.bottom, 110)
        }
        .task {
            if !addonManager.addons.isEmpty,
               addonManager.addons.contains(where: { (addonManager.healthById[$0.id] ?? .unknown) == .unknown }) {
                await addonManager.refreshAllHealth()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLUGGABLE SOURCES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                    .tracking(0.8)

                Text("Addons & Sources")
                    .font(.system(size: 34, weight: .bold))

                Text("Connect BitChord HTTP addons to search and stream Hi-Res FLAC & Lossless audio alongside YouTube Music.")
                    .font(.system(size: 13))
                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    .padding(.top, 2)
            }

            Spacer()

            Button {
                Task {
                    await addonManager.refreshAllHealth()
                    appState.showToast("Refreshed addon health")
                }
            } label: {
                HStack(spacing: 6) {
                    if addonManager.isRefreshingHealth {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("Refresh Health")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(addonManager.isRefreshingHealth || addonManager.addons.isEmpty)
            .opacity(addonManager.addons.isEmpty ? 0.45 : 1.0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
    }

    // MARK: - Add Custom Addon URL Card

    private var addCustomAddonCard: some View {
        AddonSectionCard(
            title: "Add Custom Addon URL",
            icon: "plus.circle.fill",
            subtitle: "Paste a BitChord addon root URL, token URL, or manifest.json link."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("https://www.resonance.web.id/manifest.json", text: $urlDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                        )
                        .onChange(of: urlDraft) { _, _ in
                            probePreview = nil
                            urlError = nil
                        }
                        .onSubmit {
                            Task { await performAddCustomURL() }
                        }

                    Button {
                        Task { await performTestCustomURL() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingURL {
                                ProgressView().controlSize(.small).scaleEffect(0.75)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text("Test")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedDraft.isEmpty || isTestingURL || isAddingURL)

                    Button {
                        Task { await performAddCustomURL() }
                    } label: {
                        HStack(spacing: 6) {
                            if isAddingURL {
                                ProgressView().controlSize(.small).scaleEffect(0.75)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text("Add Addon")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(trimmedDraft.isEmpty ? SoundChordTheme.accentColor(for: colorScheme).opacity(0.45) : SoundChordTheme.accentColor(for: colorScheme))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedDraft.isEmpty || isTestingURL || isAddingURL)
                }

                if let urlError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                        Text(urlError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.10))
                    )
                }

                if let preview = probePreview {
                    probePreviewBanner(preview)
                }
            }
        }
    }

    private func probePreviewBanner(_ preview: AddonProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let iconStr = preview.manifest.icon, let iconURL = URL(string: iconStr) {
                    ArtworkImage(url: iconURL, size: 32, cornerRadius: 7)
                } else {
                    addonPlaceholderIcon(size: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preview.manifest.displayName)
                            .font(.system(size: 13, weight: .bold))
                        if !preview.manifest.version.isEmpty {
                            Text("v\(preview.manifest.version)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !preview.manifest.description.isEmpty {
                        Text(preview.manifest.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                healthBadge(preview.health)
            }

            HStack(spacing: 8) {
                Label(
                    preview.manifest.allowDownloads ? "Downloads allowed" : "Playback only",
                    systemImage: preview.manifest.allowDownloads ? "arrow.down.circle" : "nosign"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if !preview.manifest.qualityOptions.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Qualities: \(preview.manifest.qualityOptions.map(\.label).joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(preview.health.isConnected ? 0.08 : 0.0))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            preview.health.isConnected ? Color.green.opacity(0.28) : Color.orange.opacity(0.35),
                            lineWidth: 0.75
                        )
                )
        )
    }

    // MARK: - Installed Sources (Priority Order)

    private var installedSourcesCard: some View {
        AddonSectionCard(
            title: "Installed Sources (Priority Order)",
            icon: "list.number",
            subtitle: "Sources are tried top-to-bottom when upgrading YouTube tracks to Lossless. Drag-free up/down buttons set priority."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if addonManager.addons.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No custom addons installed yet")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Install Resonance or ReZenOnance Qobuz in one click from the Verified Directory below, or paste any BitChord addon URL above.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, config in
                        installedAddonRow(config: config, index: index, totalCount: addonManager.addons.count)
                        Divider()
                            .overlay(SoundChordTheme.hairline(for: colorScheme))
                    }
                }

                // Always-on YouTube Music fallback row
                youtubeFallbackRow(position: addonManager.addons.count + 1)
            }
        }
    }

    private func installedAddonRow(config: AddonConfig, index: Int, totalCount: Int) -> some View {
        let health = addonManager.healthById[config.id] ?? (config.requiresBitChordAuth ? .requiresAndroidAttestation : .unknown)

        return HStack(alignment: .center, spacing: 12) {
            // Priority rank number
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            // Icon
            if let iconURL = config.resolvedIconURL {
                ArtworkImage(url: iconURL, size: 38, cornerRadius: 8)
            } else {
                addonPlaceholderIcon(size: 38)
            }

            // Details & metadata
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(config.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    healthBadge(health)
                }

                HStack(spacing: 8) {
                    Text(URL(string: config.baseURL)?.host ?? config.baseURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Label(
                        config.allowDownloads ? "Downloads allowed" : "Playback only",
                        systemImage: config.allowDownloads ? "arrow.down.circle" : "nosign"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                if !config.qualityOptions.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        Text("Preferred Quality:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: Binding(
                            get: { config.activeQuality?.value ?? config.qualityOptions.first?.value ?? "" },
                            set: { newVal in
                                addonManager.updatePreferredQuality(id: config.id, quality: newVal)
                            }
                        )) {
                            ForEach(config.qualityOptions) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                    .padding(.top, 2)
                }
            }
            .opacity(config.isEnabled ? 1.0 : 0.48)

            Spacer(minLength: 8)

            // Reorder up/down
            HStack(spacing: 4) {
                Button {
                    addonManager.moveAddon(id: config.id, direction: .up)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1.0)
                .help("Move higher in priority")

                Button {
                    addonManager.moveAddon(id: config.id, direction: .down)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(index == totalCount - 1)
                .opacity(index == totalCount - 1 ? 0.3 : 1.0)
                .help("Move lower in priority")
            }

            // Enable/Disable toggle
            Toggle("", isOn: Binding(
                get: { config.isEnabled },
                set: { _ in addonManager.toggleAddon(id: config.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(SoundChordTheme.accentColor(for: colorScheme))

            // Remove button
            Button {
                let name = config.displayName
                addonManager.removeAddon(id: config.id)
                appState.showToast("Removed addon \"\(name)\"")
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("Remove addon")
        }
        .padding(.vertical, 12)
    }

    private func youtubeFallbackRow(position: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(position)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoundChordTheme.accentColor(for: colorScheme).opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube Music")
                    .font(.system(size: 14, weight: .semibold))
                Text("Built-in full catalogue · Radio · Automatic fallback when addons don't match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Always On")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.top, 12)
    }

    // MARK: - Lossless Auto-Upgrade Settings

    private var losslessUpgradeCard: some View {
        AddonSectionCard(
            title: "Lossless Auto-Upgrade & Matching",
            icon: "waveform.badge.magnifyingglass",
            subtitle: "Automatically substitute YouTube Music playback with Hi-Res / Lossless FLAC from your enabled addons."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic Lossless Upgrade")
                            .font(.system(size: 13, weight: .semibold))
                        Text("When Streaming Quality is set to Lossless, match playing YouTube tracks against enabled addons first.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.addonLosslessUpgrade },
                        set: { enabled in
                            appState.updateSettings { $0.addonLosslessUpgrade = enabled }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SoundChordTheme.accentColor(for: colorScheme))
                }

                if settings.addonLosslessUpgrade && settings.streamQuality != .lossless {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Streaming Quality is currently \"\(settings.streamQuality.displayName)\". Switch to Lossless to activate automatic addon upgrades.")
                            .font(.system(size: 12))
                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        Spacer()
                        Button("Switch to Lossless") {
                            appState.updateSettings { $0.streamQuality = .lossless }
                            appState.showToast("Streaming quality set to Lossless")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.10))
                    )
                }

                Divider().overlay(SoundChordTheme.hairline(for: colorScheme))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track Duration Tolerance")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Maximum length difference allowed between a YouTube track and an addon FLAC match.")
                                .font(.system(size: 12))
                                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                        }
                        Spacer()
                        Text("±\(Int(settings.addonDurationToleranceSec.rounded()))s")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            .frame(minWidth: 42, alignment: .trailing)
                    }

                    Slider(
                        value: Binding(
                            get: { settings.addonDurationToleranceSec },
                            set: { newVal in
                                appState.updateSettings { $0.addonDurationToleranceSec = newVal.rounded() }
                            }
                        ),
                        in: 0...15,
                        step: 1
                    )
                    .tint(SoundChordTheme.accentColor(for: colorScheme))
                }
            }
        }
    }

    // MARK: - Verified BitChord Addons Directory

    private var curatedDirectoryCard: some View {
        AddonSectionCard(
            title: "Verified BitChord Addons Directory",
            icon: "sparkles.rectangle.stack.fill",
            subtitle: "Live-verified community addons and self-hosted tools compatible with SoundChord."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AddonManager.curatedCatalog) { preset in
                    curatedPresetRow(preset)
                }
            }
        }
    }

    private func curatedPresetRow(_ preset: CuratedAddonPreset) -> some View {
        let installed = preset.manifestURL.map { addonManager.isInstalled(manifestOrBaseURL: $0) } ?? false
        let isInstalling = installingPresetIds.contains(preset.id)
        let displayURL = preset.manifestURL ?? preset.setupURL ?? ""
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(preset.name)
                            .font(.system(size: 14, weight: .bold))

                        Text(preset.category)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(preset.isDirectInstall ? accent : SoundChordTheme.secondaryText(for: colorScheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(preset.isDirectInstall ? accent.opacity(0.14) : Color.primary.opacity(0.07))
                            )
                    }

                    Text(preset.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))

                    Text(preset.note)
                        .font(.system(size: 11))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme).opacity(0.9))
                }

                Spacer(minLength: 12)

                if preset.isDirectInstall, let manifestURL = preset.manifestURL {
                    if installed {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                            Text("Installed")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.green.opacity(0.14))
                        )
                    } else {
                        Button {
                            Task { await installPreset(preset, manifestURL: manifestURL) }
                        } label: {
                            HStack(spacing: 6) {
                                if isInstalling {
                                    ProgressView().controlSize(.small).scaleEffect(0.75)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(isInstalling ? "Installing..." : "Install")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(accentFg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstalling)
                    }
                } else if let setupURLString = preset.setupURL, let setupURL = URL(string: setupURLString) {
                    Button {
                        NSWorkspace.shared.open(setupURL)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "safari.fill")
                                .font(.system(size: 12))
                            Text("Open Setup Page")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.09))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !displayURL.isEmpty {
                HStack(spacing: 8) {
                    Text(displayURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayURL, forType: .string)
                        appState.showToast("Copied URL to clipboard")
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    // MARK: - Helpers & Actions

    private var trimmedDraft: String {
        urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performTestCustomURL() async {
        guard !trimmedDraft.isEmpty else { return }
        isTestingURL = true
        urlError = nil
        probePreview = nil
        defer { isTestingURL = false }

        do {
            let result = try await addonManager.testAddonURL(trimmedDraft)
            probePreview = result
        } catch {
            urlError = error.localizedDescription
        }
    }

    private func performAddCustomURL() async {
        guard !trimmedDraft.isEmpty else { return }
        isAddingURL = true
        urlError = nil
        defer { isAddingURL = false }

        do {
            let added = try await addonManager.addAddon(from: trimmedDraft)
            urlDraft = ""
            probePreview = nil
            appState.showToast("Installed addon \"\(added.displayName)\"")
        } catch {
            urlError = error.localizedDescription
        }
    }

    private func installPreset(_ preset: CuratedAddonPreset, manifestURL: String) async {
        installingPresetIds.insert(preset.id)
        defer { installingPresetIds.remove(preset.id) }

        do {
            let added = try await addonManager.addAddon(from: manifestURL)
            appState.showToast("Installed \"\(added.displayName)\"")
        } catch {
            appState.showError("Failed to install \(preset.name): \(error.localizedDescription)")
        }
    }

    private func addonPlaceholderIcon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: size, height: size)
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
        }
    }

    @ViewBuilder
    private func healthBadge(_ status: AddonHealthStatus) -> some View {
        switch status {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

        case .connected:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.14)))

        case .requiresAndroidAttestation:
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 9))
                Text(status.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.15)))

        case .unreachable:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.14)))

        case .unknown:
            Text("Not checked")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

// MARK: - Section Card Container

private struct AddonSectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard)
    }
}
