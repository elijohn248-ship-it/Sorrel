// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Drift",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(name: "Drift", path: "Sources/Drift")
    ]
)
