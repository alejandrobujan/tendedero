// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageLine",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .target(name: "ClipboardSupport"),
        .executableTarget(name: "Tendedero", dependencies: ["ClipboardSupport"], path: "Sources/Tendedero", exclude: ["Resources"]),
        .testTarget(name: "ClipboardSupportTests", dependencies: ["ClipboardSupport"]),
        .testTarget(name: "LineTests", dependencies: ["Tendedero"])
    ]
)
