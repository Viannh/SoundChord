import SwiftUI

/// Dynamic 4-color artwork-sampled animated backdrop using macOS 15 `MeshGradient`.
/// Mirrors SoundChord's organic drifting control points with smooth 1.4s color transitions
/// whenever the track palette changes.
public struct MeshGradientBackground: View {
    public let colors: [Color]
    public var isAnimating: Bool
    public var vignetteOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        colors: [Color],
        isAnimating: Bool = true,
        vignetteOpacity: Double = 0.42
    ) {
        self.colors = colors
        self.isAnimating = isAnimating
        self.vignetteOpacity = vignetteOpacity
    }

    private var fourColors: [Color] {
        let fallback = AppState.defaultPaletteColors
        let merged = colors + fallback
        return Array(merged.prefix(4))
    }

    public var body: some View {
        let palette = fourColors
        let c0 = palette[0]
        let c1 = palette[1]
        let c2 = palette[2]
        let c3 = palette[3]
        let shouldAnimate = isAnimating && !reduceMotion

        ZStack {
            // Deep base underneath so edges never flash
            c0.opacity(0.35)
                .background(Color.black)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { timeline in
                let t = shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0.0
                let points = animatedControlPoints(at: t)
                let meshColors: [Color] = [
                    c0,
                    c1.opacity(0.92),
                    c1,
                    c2.opacity(0.92),
                    c3,
                    c0.opacity(0.88),
                    c2,
                    c3.opacity(0.90),
                    c1.opacity(0.85)
                ]

                MeshGradient(
                    width: 3,
                    height: 3,
                    points: points,
                    colors: meshColors,
                    smoothsColors: true
                )
                .scaleEffect(1.18)
                .blur(radius: 28)
                .animation(.easeInOut(duration: 1.4), value: colors)
            }

            // Soft vignette & vertical legibility scrim for white lyrics and controls
            LinearGradient(
                colors: [
                    Color.black.opacity(vignetteOpacity * 0.42),
                    Color.black.opacity(vignetteOpacity * 0.65),
                    Color.black.opacity(vignetteOpacity * 1.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(vignetteOpacity * 0.72)
                ],
                center: .center,
                startRadius: 180,
                endRadius: 920
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    /// Computes a 3x3 grid of control points whose interior and edge midpoints drift
    /// organically using irrational speed ratios.
    private func animatedControlPoints(at time: Double) -> [SIMD2<Float>] {
        let p = Float(time * 0.22)
        // Irrational-like speed ratios: 1.0, -0.7, 0.85, -1.15
        let topMidX = clamp(0.50 + 0.18 * cos(p * 1.0 + 0.4), min: 0.24, max: 0.76)
        let leftMidY = clamp(0.50 + 0.18 * sin(p * -0.7 + 1.5), min: 0.24, max: 0.76)
        let centerX = clamp(0.50 + 0.20 * cos(p * 0.85 + 2.3), min: 0.26, max: 0.74)
        let centerY = clamp(0.50 + 0.20 * sin(p * -1.15 + 0.9), min: 0.26, max: 0.74)
        let rightMidY = clamp(0.50 + 0.18 * cos(p * 0.78 + 3.1), min: 0.24, max: 0.76)
        let bottomMidX = clamp(0.50 + 0.18 * sin(p * -0.92 + 4.0), min: 0.24, max: 0.76)

        return [
            SIMD2(0.0, 0.0),         SIMD2(topMidX, 0.0),       SIMD2(1.0, 0.0),
            SIMD2(0.0, leftMidY),    SIMD2(centerX, centerY),   SIMD2(1.0, rightMidY),
            SIMD2(0.0, 1.0),         SIMD2(bottomMidX, 1.0),    SIMD2(1.0, 1.0)
        ]
    }

    private func clamp(_ value: Float, min low: Float, max high: Float) -> Float {
        Swift.max(low, Swift.min(high, value))
    }
}
