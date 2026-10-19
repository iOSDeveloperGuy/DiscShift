// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DiscDock", platforms: [.macOS(.v14)], products: [
    .executable(name: "DiscDock", targets: ["DiscDock"])
], targets: [
    .target(name: "DiscDockCore"),
    .executableTarget(name: "DiscDock", dependencies: ["DiscDockCore"]),
    .testTarget(name: "DiscDockCoreTests", dependencies: ["DiscDockCore"]),
    .testTarget(name: "DiscDockAppTests", dependencies: ["DiscDock", "DiscDockCore"])
])
