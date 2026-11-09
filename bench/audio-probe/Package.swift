// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "audio-probe",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "audio-probe", path: "Sources")]
)
