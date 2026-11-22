import AppKit
import SwiftUI

// MARK: - SoundChord 2-Direction Design System (Apple Music Light + Spotify Dark)

public enum SoundChordTheme {
    // MARK: - Light Mode Tokens (Apple Music)

    public static let lightAccent = Color(red: 0xD6 / 255.0, green: 0x00 / 255.0, blue: 0x17 / 255.0)
    public static let lightVibrantAccent = Color(red: 0xFA / 255.0, green: 0x2D / 255.0, blue: 0x48 / 255.0)
    public static let lightBackground = Color(red: 1.0, green: 1.0, blue: 1.0)
    public static let lightSurface = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
    public static let lightSurfaceHover = Color(red: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xEF / 255.0)
    public static let lightPrimaryText = Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)
    public static let lightSecondaryText = Color(red: 0x51 / 255.0, green: 0x51 / 255.0, blue: 0x54 / 255.0)
    public static let lightHairline = Color.black.opacity(0.09)

    // MARK: - Dark Mode Tokens (Spotify)

    public static let darkAccent = Color(red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0)
    public static let darkOuterFrame = Color.black
    public static let darkBackground = Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    public static let darkSurface = Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0)
    public static let darkSurfaceHover = Color(red: 0x28 / 255.0, green: 0x28 / 255.0, blue: 0x28 / 255.0)
    public static let darkSurfaceVariant = Color(red: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x24 / 255.0)
    public static let darkPrimaryText = Color.white
    public static let darkSecondaryText = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB3 / 255.0)
    public static let darkHairline = Color.white.opacity(0.08)

    // MARK: - Dynamic Compatibility Tokens

    public static let accentColor: Color = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0, alpha: 1.0)
                : NSColor(srgbRed: 0xD6 / 255.0, green: 0x00 / 255.0, blue: 0x17 / 255.0, alpha: 1.0)
        }
    )

    public static let secondaryText: Color = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB3 / 255.0, alpha: 1.0)
                : NSColor(srgbRed: 0x51 / 255.0, green: 0x51 / 255.0, blue: 0x54 / 255.0, alpha: 1.0)
        }
    )

    public static let hairline: Color = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.09)
        }
    )

    // MARK: - Radii Tokens

    public static let cornerRadiusPanel: CGFloat = 10
    public static let cornerRadiusCard: CGFloat = 8
    public static let cornerRadiusBeatCell: CGFloat = 6
    public static let cornerRadiusArtworkSmall: CGFloat = 6

    // MARK: - Scheme-Aware Helpers

    public static func accentColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkAccent : lightAccent
    }

    public static func accentForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    public static func windowBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOuterFrame : lightBackground
    }

    public static func panelBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    public static func pageBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    public static func cardBackground(for scheme: ColorScheme, hovered: Bool = false) -> Color {
        if scheme == .dark {
            return hovered ? darkSurfaceHover : darkSurface
        } else {
            return hovered ? lightSurfaceHover : lightSurface
        }
    }

    public static func elevatedBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurfaceVariant : lightSurfaceHover
    }

    public static func primaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkPrimaryText : lightPrimaryText
    }

    public static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSecondaryText : lightSecondaryText
    }

    public static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkHairline : lightHairline
    }

    public static func playerBarBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkOuterFrame : lightSurface
    }

    public static func lightGlassTint(opacity: Double = 0.72) -> Color {
        let clamped = max(0.35, min(0.92, opacity))
        return lightSurface.opacity(clamped * 0.76)
    }

    static func glassTint(for scheme: ColorScheme, opacity: Double = 0.72) -> Color {
        let clamped = max(0.3, min(1.0, opacity))
        if scheme == .dark {
            return darkBackground.opacity(0.95)
        } else {
            return lightSurface.opacity(clamped * 0.76)
        }
    }
}

public typealias BitChordTheme = SoundChordTheme

// MARK: - NSVisualEffectView Bridge (Used strictly for Light Mode Sidebar & Light Floating Player Bar)

public struct VisualEffectBlur: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != .active {
            nsView.state = .active
        }
    }
}

// MARK: - Artwork Image Cache & Loader

final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 48 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    @MainActor
    func loadImage(from url: URL) async -> NSImage? {
        if let existing = cache.object(forKey: url as NSURL) {
            return existing
        }

        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url)
                }.value
            } else {
                let (fetched, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                data = fetched
            }

            guard let image = NSImage(data: data) else { return nil }
            let pixelCost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: url as NSURL, cost: max(1, pixelCost))
            return image
        } catch {
            return nil
        }
    }
}

public struct ArtworkImage: View {
    public let url: URL?
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public let isCircle: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage?
    @State private var loadedURL: URL?

    public init(
        url: URL?,
        size: CGFloat,
        cornerRadius: CGFloat = SoundChordTheme.cornerRadiusCard,
        isCircle: Bool = false
    ) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
        if let url, let cached = ArtworkImageCache.shared.cachedImage(for: url) {
            _loadedImage = State(initialValue: cached)
            _loadedURL = State(initialValue: url)
        }
    }

    public var body: some View {
        ZStack {
            placeholderView

            if let image = displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .overlay(borderOverlay)
        .task(id: url) {
            await fetchIfNeeded()
        }
    }

    private var displayedImage: NSImage? {
        guard let url else { return nil }
        if loadedURL == url, let loadedImage {
            return loadedImage
        }
        return ArtworkImageCache.shared.cachedImage(for: url)
    }

    private var placeholderView: some View {
        ZStack {
            SoundChordTheme.cardBackground(for: colorScheme)
            Image(systemName: isCircle ? "person.fill" : "music.note")
                .font(.system(size: max(12, size * 0.34), weight: .medium))
                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme).opacity(0.65))
        }
    }

    private var clipShape: AnyShape {
        if isCircle {
            AnyShape(Circle())
        } else {
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isCircle {
            Circle()
                .strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
        }
    }

    private func fetchIfNeeded() async {
        guard let url else {
            loadedImage = nil
            loadedURL = nil
            return
        }
        if let cached = ArtworkImageCache.shared.cachedImage(for: url) {
            loadedImage = cached
            loadedURL = url
            return
        }
        let fetched = await ArtworkImageCache.shared.loadImage(from: url)
        guard !Task.isCancelled else { return }
        if let fetched {
            withAnimation(.easeOut(duration: 0.22)) {
                loadedImage = fetched
                loadedURL = url
            }
        }
    }
}

// MARK: - Crisp Card Surface Modifier (No Glass Blur Overdose)

private struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(SoundChordTheme.cardBackground(for: colorScheme, hovered: isHovered)))
            .overlay(
                shape.strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1)
            )
    }
}

public extension View {
    func soundCardSurface(
        cornerRadius: CGFloat = SoundChordTheme.cornerRadiusCard,
        isHovered: Bool = false
    ) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius, isHovered: isHovered))
    }

    func glassSurface(cornerRadius: CGFloat = SoundChordTheme.cornerRadiusCard) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius, isHovered: false))
    }
}

// MARK: - Animated Playing Equalizer Bars (Shared Chrome Helper)

struct MiniEqualizerBars: View {
    let isPlaying: Bool
    var tint: Color = SoundChordTheme.accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                bar(phase: t * 5.2 + 0.0)
                bar(phase: t * 6.8 + 1.4)
                bar(phase: t * 4.5 + 2.7)
            }
            .frame(width: 13, height: 13, alignment: .bottom)
        }
    }

    private func bar(phase: Double) -> some View {
        let height: CGFloat = isPlaying ? CGFloat(4.0 + 9.0 * (0.5 + 0.5 * sin(phase))) : 3.5
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tint)
            .frame(width: 3, height: height)
    }
}
