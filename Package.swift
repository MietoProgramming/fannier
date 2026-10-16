// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "fannier",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fannier", targets: ["FannierApp"]),
        .executable(name: "fanierd", targets: ["Fannierd"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
        .library(name: "FanCore", targets: ["FanCore"]),
    ],
    targets: [
        .target(name: "FanSMC"),
        .target(name: "FanCore", dependencies: ["FanSMC"]),
        .executableTarget(name: "FannierApp", dependencies: ["FanCore"]),
        .executableTarget(name: "Fannierd", dependencies: ["FanCore"]),
        .executableTarget(name: "fanctl", dependencies: ["FanCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"]),
    ]
)
