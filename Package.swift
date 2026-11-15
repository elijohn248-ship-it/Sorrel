// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sorrel",
    platforms: [.macOS("15.4")],
    targets: [
        // Shared by the app and its updater service: the update manifest, signature checks, the XPC protocol.
        .target(name: "SorrelUpdateCore", path: "Sources/SorrelUpdateCore"),
        .executableTarget(name: "Sorrel", dependencies: ["SorrelUpdateCore"], path: "Sources/Sorrel"),
        // The unsandboxed XPC service that swaps the app bundle (build.sh puts it in Contents/XPCServices).
        .executableTarget(name: "SorrelUpdater", dependencies: ["SorrelUpdateCore"], path: "Sources/SorrelUpdater"),
    ]
)
