// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacGuard", targets: ["MacGuard"]),
        .library(name: "MacGuardCore", targets: ["MacGuardCore"]),
    ],
    targets: [
        .target(name: "MacGuardCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MacGuard", dependencies: ["MacGuardCore"]),
        .testTarget(name: "MacGuardTests", dependencies: ["MacGuardCore"]),
    ]
)
