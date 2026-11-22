#!/usr/bin/env swift
// generate_icon.swift
// Generates a macOS Sequoia AppIcon.iconset (16x16 through 512x512@2x)
// using Assets/AppIcon-1024.png when present (clipped to macOS squircle),
// or a crisp vector 3-arc emblem fallback.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - CLI Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift generate_icon.swift <output-iconset-dir> [--icns <output-icns-path>] [--icon <png-path>]\n", stderr)
    exit(1)
}

let iconsetPath = args[1]
var icnsOutputPath: String? = nil
var iconPNGPath: String? = nil

var argIndex = 2
while argIndex < args.count {
    switch args[argIndex] {
    case "--icns":
        if argIndex + 1 < args.count {
            icnsOutputPath = args[argIndex + 1]
            argIndex += 2
        } else {
            argIndex += 1
        }
    case "--upstream", "--icon":
        if argIndex + 1 < args.count {
            iconPNGPath = args[argIndex + 1]
            argIndex += 2
        } else {
            argIndex += 1
        }
    default:
        if iconPNGPath == nil {
            iconPNGPath = args[argIndex]
        }
        argIndex += 1
    }
}

let fm = FileManager.default
if iconPNGPath == nil {
    let scriptURL = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
    let candidate = scriptURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Assets/AppIcon-1024.png")
    if fm.fileExists(atPath: candidate.path) {
        iconPNGPath = candidate.path
    }
}
let iconsetURL = URL(fileURLWithPath: iconsetPath, isDirectory: true)

do {
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    fputs("Error creating iconset directory: \(error)\n", stderr)
    exit(1)
}

// MARK: - macOS Squircle Path (Continuous Superellipse Approximation)

/// Creates a continuous macOS Big Sur / Sequoia squircle path inside `rect`.
func makeMacOSSquirclePath(in rect: CGRect) -> CGPath {
    // Apple HIG macOS icon corner radius is ~22.37% of the squircle width.
    let radius = min(rect.width, rect.height) * 0.2237
    let bezier = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let cgPath = CGMutablePath()
    var points = [NSPoint](repeating: .zero, count: 3)
    for index in 0..<bezier.elementCount {
        let type = bezier.element(at: index, associatedPoints: &points)
        switch type {
        case .moveTo:
            cgPath.move(to: points[0])
        case .lineTo:
            cgPath.addLine(to: points[0])
        case .curveTo, .cubicCurveTo:
            cgPath.addCurve(to: points[2], control1: points[0], control2: points[1])
        case .quadraticCurveTo:
            cgPath.addQuadCurve(to: points[1], control: points[0])
        case .closePath:
            cgPath.closeSubpath()
        @unknown default:
            break
        }
    }
    return cgPath
}

// MARK: - BitChord Official 3-Arc Emblem Vector Path

/// Builds the exact 3-arc BitChord emblem path from upstream `favicon.svg` (1024x1024 viewBox),
/// mapped cleanly into `targetRect` (in CoreGraphics bottom-left coordinate space).
func makeBitChordEmblemPath(in targetRect: CGRect) -> CGPath {
    let path = CGMutablePath()

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: targetRect.minX + (x / 1024.0) * targetRect.width,
            y: targetRect.maxY - (y / 1024.0) * targetRect.height
        )
    }

    // Arc 1 (bottom, widest)
    path.move(to: pt(142.673, 587.458))
    path.addCurve(to: pt(208.339, 570.696), control1: pt(156.137, 564.680), control2: pt(185.634, 557.171))
    path.addLine(to: pt(208.363, 570.696))
    path.addCurve(to: pt(803.759, 629.960), control1: pt(373.538, 668.803), control2: pt(646.056, 677.824))
    path.addCurve(to: pt(863.537, 661.900), control1: pt(829.083, 622.280), control2: pt(855.863, 636.576))
    path.addCurve(to: pt(831.585, 721.698), control1: pt(871.211, 687.236), control2: pt(856.927, 713.999))
    path.addCurve(to: pt(159.441, 653.143), control1: pt(650.553, 776.654), control2: pt(349.610, 766.036))
    path.addCurve(to: pt(142.673, 587.458), control1: pt(136.614, 639.624), control2: pt(129.148, 610.206))
    path.closeSubpath()

    // Arc 2 (middle)
    path.move(to: pt(213.749, 425.386))
    path.addCurve(to: pt(268.705, 412.198), control1: pt(225.316, 406.567), control2: pt(249.917, 400.631))
    path.addCurve(to: pt(779.396, 471.951), control1: pt(406.463, 496.890), control2: pt(616.454, 521.412))
    path.addCurve(to: pt(829.260, 498.574), control1: pt(800.527, 465.569), control2: pt(822.846, 477.478))
    path.addCurve(to: pt(802.614, 548.408), control1: pt(835.624, 519.705), control2: pt(823.709, 541.982))
    path.addCurve(to: pt(226.906, 480.312), control1: pt(616.491, 604.882), control2: pt(385.105, 577.526))
    path.addCurve(to: pt(213.749, 425.386), control1: pt(208.118, 468.745), control2: pt(202.183, 444.150))
    path.closeSubpath()

    // Arc 3 (top)
    path.move(to: pt(276.478, 285.823))
    path.addCurve(to: pt(320.418, 275.235), control1: pt(285.657, 270.768), control2: pt(305.363, 265.994))
    path.addCurve(to: pt(770.619, 324.622), control1: pt(440.747, 348.734), control2: pt(592.225, 365.381))
    path.addCurve(to: pt(808.862, 348.673), control1: pt(787.810, 320.706), control2: pt(804.946, 331.476))
    path.addCurve(to: pt(784.836, 386.922), control1: pt(812.797, 365.870), control2: pt(802.069, 383.005))
    path.addCurve(to: pt(287.064, 329.763), control1: pt(589.612, 431.542), control2: pt(422.154, 412.320))
    path.addCurve(to: pt(276.478, 285.823), control1: pt(272.010, 320.522), control2: pt(267.237, 300.877))
    path.closeSubpath()

    return path
}

// MARK: - Master 1024x1024 Renderer

func loadCGImage(at path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        return cg
    }
    if let nsImage = NSImage(contentsOfFile: path) {
        return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    return nil
}

func renderMasterIcon(iconPNGPath: String?) -> CGImage {
    let canvasSize = 1024
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Error: Unable to create CoreGraphics context.\n", stderr)
        exit(1)
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Apple HIG macOS icon grid: 824x824 squircle centered in 1024x1024 canvas
    let inset: CGFloat = 100
    let squircleRect = CGRect(x: inset, y: inset, width: CGFloat(canvasSize) - inset * 2, height: CGFloat(canvasSize) - inset * 2)
    let squirclePath = makeMacOSSquirclePath(in: squircleRect)

    // 1. Soft macOS Dock elevation shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 32,
        color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.36)
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.04, blue: 0.06, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Clip to squircle for all interior artwork
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    if let pngPath = iconPNGPath,
       let sourceCG = loadCGImage(at: pngPath) {
        // Composite custom app icon artwork cleanly into the macOS squircle
        ctx.draw(sourceCG, in: squircleRect)
    } else {
        // Native high-DPI BitChord Liquid Glass + Apple Red gradient background
        let bgColors = [
            CGColor(srgbRed: 0.992, green: 0.388, blue: 0.478, alpha: 1.0), // #FD637A top highlight
            CGColor(srgbRed: 0.980, green: 0.176, blue: 0.282, alpha: 1.0), // #FA2D48 BitChord Apple Red
            CGColor(srgbRed: 0.855, green: 0.055, blue: 0.176, alpha: 1.0)  // #DA0E2D deep crimson base
        ] as CFArray
        let bgLocations: [CGFloat] = [0.0, 0.48, 1.0]
        if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
            ctx.drawLinearGradient(
                bgGradient,
                start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
                end: CGPoint(x: squircleRect.midX, y: squircleRect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Subtle Liquid Glass top radial bloom
        let bloomColors = [
            CGColor(srgbRed: 1.0, green: 0.85, blue: 0.88, alpha: 0.32),
            CGColor(srgbRed: 1.0, green: 0.85, blue: 0.88, alpha: 0.0)
        ] as CFArray
        if let bloomGradient = CGGradient(colorsSpace: colorSpace, colors: bloomColors, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(
                bloomGradient,
                startCenter: CGPoint(x: squircleRect.minX + squircleRect.width * 0.34, y: squircleRect.maxY - squircleRect.height * 0.14),
                startRadius: 0,
                endCenter: CGPoint(x: squircleRect.midX, y: squircleRect.maxY - squircleRect.height * 0.28),
                endRadius: squircleRect.width * 0.68,
                options: [.drawsBeforeStartLocation]
            )
        }

        // Subtle bottom vignette for macOS icon depth
        let vignetteColors = [
            CGColor(srgbRed: 0.22, green: 0.0, blue: 0.05, alpha: 0.28),
            CGColor(srgbRed: 0.22, green: 0.0, blue: 0.05, alpha: 0.0)
        ] as CFArray
        if let vignetteGradient = CGGradient(colorsSpace: colorSpace, colors: vignetteColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                vignetteGradient,
                start: CGPoint(x: squircleRect.midX, y: squircleRect.minY),
                end: CGPoint(x: squircleRect.midX, y: squircleRect.minY + squircleRect.height * 0.32),
                options: []
            )
        }

        // Crisp 3-arc BitChord emblem with soft elevation shadow
        let emblemPath = makeBitChordEmblemPath(in: squircleRect)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10),
            blur: 22,
            color: CGColor(srgbRed: 0.36, green: 0.0, blue: 0.07, alpha: 0.42)
        )
        ctx.addPath(emblemPath)
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3. Liquid Glass specular top-edge sheen + inner bevel rim
    let rimInsetRect = squircleRect.insetBy(dx: 3.0, dy: 3.0)
    let rimPath = makeMacOSSquirclePath(in: rimInsetRect)
    ctx.saveGState()
    ctx.addPath(rimPath)
    ctx.setLineWidth(6.0)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimColors = [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.38),
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.08),
        CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.14)
    ] as CFArray
    if let rimGradient = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            rimGradient,
            start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
            end: CGPoint(x: squircleRect.midX, y: squircleRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.restoreGState() // end squircle clip

    guard let image = ctx.makeImage() else {
        fputs("Error: Failed to capture rendered icon CGImage.\n", stderr)
        exit(1)
    }
    return image
}

// MARK: - Downscale & Write PNGs

func writePNG(_ masterImage: CGImage, pixelSize: Int, pointSize: Int, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "SoundChordIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate \(pixelSize)px context"])
    }

    ctx.interpolationQuality = .high
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

    guard let scaled = ctx.makeImage() else {
        throw NSError(domain: "SoundChordIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to produce scaled image"])
    }

    let rep = NSBitmapImageRep(cgImage: scaled)
    rep.size = NSSize(width: pointSize, height: pointSize)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SoundChordIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: url, options: .atomic)
}

let masterImage = renderMasterIcon(iconPNGPath: iconPNGPath)

let iconSpecs: [(filename: String, pixels: Int, points: Int, icnsType: String)] = [
    ("icon_16x16.png", 16, 16, "icp4"),
    ("icon_16x16@2x.png", 32, 16, "ic11"),
    ("icon_32x32.png", 32, 32, "icp5"),
    ("icon_32x32@2x.png", 64, 32, "ic12"),
    ("icon_128x128.png", 128, 128, "ic07"),
    ("icon_128x128@2x.png", 256, 128, "ic13"),
    ("icon_256x256.png", 256, 256, "ic08"),
    ("icon_256x256@2x.png", 512, 256, "ic14"),
    ("icon_512x512.png", 512, 512, "ic09"),
    ("icon_512x512@2x.png", 1024, 512, "ic10")
]

func writeMultiResICNS(chunks: [(fourCC: String, data: Data)], to url: URL) throws {
    func appendBE32(_ value: UInt32, to buffer: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { buffer.append(contentsOf: $0) }
    }

    // Build TOC chunk (lists each icon type + chunk length)
    var tocBody = Data()
    for chunk in chunks {
        tocBody.append(contentsOf: chunk.fourCC.utf8.prefix(4))
        appendBE32(UInt32(8 + chunk.data.count), to: &tocBody)
    }

    var body = Data()
    body.append(contentsOf: "TOC ".utf8)
    appendBE32(UInt32(8 + tocBody.count), to: &body)
    body.append(tocBody)

    for chunk in chunks {
        body.append(contentsOf: chunk.fourCC.utf8.prefix(4))
        appendBE32(UInt32(8 + chunk.data.count), to: &body)
        body.append(chunk.data)
    }

    var fileData = Data()
    fileData.append(contentsOf: "icns".utf8)
    appendBE32(UInt32(8 + body.count), to: &fileData)
    fileData.append(body)
    try fileData.write(to: url, options: .atomic)
}

do {
    var icnsChunks: [(fourCC: String, data: Data)] = []
    for spec in iconSpecs {
        let outURL = iconsetURL.appendingPathComponent(spec.filename)
        try writePNG(masterImage, pixelSize: spec.pixels, pointSize: spec.points, to: outURL)
        if icnsOutputPath != nil {
            let pngData = try Data(contentsOf: outURL)
            icnsChunks.append((spec.icnsType, pngData))
        }
    }
    print("Generated \(iconSpecs.count) iconset PNGs in \(iconsetURL.path)")

    if let icnsPath = icnsOutputPath {
        let icnsURL = URL(fileURLWithPath: icnsPath)
        try writeMultiResICNS(chunks: icnsChunks, to: icnsURL)
        print("Wrote multi-resolution ICNS (\(icnsChunks.count) representations) to \(icnsURL.path)")
    }
} catch {
    fputs("Error writing iconset: \(error)\n", stderr)
    exit(1)
}
