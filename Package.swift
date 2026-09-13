// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LookMomNoHands",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LookMomNoHands",
            path: "Sources/LookMomNoHands",
            // The speaker-verification model (PLAN-SPEAKER-VERIFICATION.md).
            // SwiftPM compiles .mlpackage resources with coremlc on macOS into
            // SpeakerEmbedder.mlmodelc inside LookMomNoHands_LookMomNoHands.bundle
            // next to the binary; Scripts/common.sh assemble_app copies that
            // bundle into the .app, and SpeakerVerifier.locateModel finds it in
            // both places (no Bundle.module dependency).
            resources: [.process("Resources/SpeakerEmbedder.mlpackage")]
        ),
        .testTarget(
            name: "LookMomNoHandsTests",
            dependencies: ["LookMomNoHands"],
            path: "Tests/LookMomNoHandsTests"
        )
    ]
)
