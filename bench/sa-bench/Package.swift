// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "sa-bench",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "sa-bench", path: "Sources")
    ]
)
