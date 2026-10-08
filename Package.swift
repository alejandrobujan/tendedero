// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tendedero",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tendedero", path: "Sources/Tendedero"),
        .testTarget(name: "TendederoTests", dependencies: ["Tendedero"])
    ]
)
