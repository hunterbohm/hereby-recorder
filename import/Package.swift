// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LMLImport",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ImportCore", targets: ["ImportCore"]), .executable(name: "lml-import", targets: ["lml-import"])],
    targets: [
        .target(name: "ImportCore"),
        .executableTarget(name: "lml-import", dependencies: ["ImportCore"]),
        .testTarget(name: "ImportCoreTests", dependencies: ["ImportCore"])
    ]
)
