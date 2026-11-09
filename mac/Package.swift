// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveMeetingListener",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LMLCore", targets: ["LMLCore"]),
        .library(name: "LMLPanel", targets: ["LMLPanel"]),
        .executable(name: "lml", targets: ["lml"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")
    ],
    targets: [
        .target(name: "LMLCore"),
        .target(name: "LMLPanel", dependencies: ["LMLCore"], exclude: ["STATES.md"]),
        .target(name: "LMLPanelFakes", dependencies: ["LMLCore", "LMLPanel"]),
        .executableTarget(name: "lml", dependencies: ["LMLCore", "LMLPanel", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "lml-mic", dependencies: ["LMLCore"]),
        .executableTarget(name: "lml-panel-snapshots", dependencies: ["LMLCore", "LMLPanel", "LMLPanelFakes"]),
        .testTarget(name: "LMLCoreTests", dependencies: ["LMLCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LMLRuntimeTests", dependencies: ["lml"]),
        .testTarget(name: "LMLPanelTests", dependencies: ["LMLCore", "LMLPanel", "LMLPanelFakes"])
    ]
)
