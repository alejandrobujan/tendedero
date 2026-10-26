// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tendedero",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(
            name: "Tendedero",
            dependencies: ["CaptureSettings"],
            path: "Sources/Tendedero",
            exclude: ["Resources"]),
        // The save-folder logic, on its own so the build can check it without
        // compiling the SwiftUI app. The app target uses it too.
        .target(name: "CaptureSettings", path: "Sources/CaptureSettings"),
        .executableTarget(
            name: "CaptureSettingsCheck",
            dependencies: ["CaptureSettings"],
            path: "Sources/CaptureSettingsCheck"),
    ]
)
