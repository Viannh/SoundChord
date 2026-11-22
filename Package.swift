// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibDir = packageDir
    .appendingPathComponent("RustDSP/target/x86_64-apple-darwin/release")
    .path

let package = Package(
    name: "SoundChord",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SoundChord", targets: ["SoundChord"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CSoundChordDSP",
            path: "RustDSP/include",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "SoundChord",
            dependencies: ["CSoundChordDSP"],
            path: "Sources/SoundChord",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-L\(rustLibDir)", "-lsoundchord_dsp"])
            ]
        ),
        .testTarget(
            name: "SoundChordTests",
            dependencies: ["SoundChord"],
            path: "Tests/SoundChordTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
