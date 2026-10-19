// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DiscShift", platforms: [.macOS(.v14)], products: [
    .executable(name: "DiscShift", targets: ["DiscShift"])
], targets: [
    .target(name: "DiscShiftCore"),
    .executableTarget(name: "DiscShift", dependencies: ["DiscShiftCore"]),
    .testTarget(name: "DiscShiftCoreTests", dependencies: ["DiscShiftCore"]),
    .testTarget(name: "DiscShiftAppTests", dependencies: ["DiscShift", "DiscShiftCore"])
])
