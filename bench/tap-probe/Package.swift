// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "tap-probe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "tap-probe", path: "Sources")
    ]
)
