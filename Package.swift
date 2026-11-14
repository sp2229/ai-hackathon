// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Argmax on-device speech SDK (WhisperKit = transcription, SpeakerKit = diarization).
        // To use Argmax Pro, see README "Upgrading to Argmax Pro".
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "0.18.0"),
        // Native LaTeX math rendering (CoreText, offline) for equation-heavy notes
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Notes",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources/Notes"
        ),
    ]
)
