// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LookMomNoHands",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LookMomNoHands",
            path: "Sources/LookMomNoHands"
        )
    ]
)
