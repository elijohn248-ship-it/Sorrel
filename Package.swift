// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sorrel",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(name: "Sorrel", path: "Sources/Sorrel")
    ]
)
