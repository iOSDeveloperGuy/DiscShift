// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DiscShift", platforms: [.macOS(.v14)], products: [
    .executable(name: "DiscShift", targets: ["DiscShift"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
], targets: [
    .target(name: "DiscShiftCore"),
    .executableTarget(name: "DiscShift", dependencies: ["DiscShiftCore", .product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "DiscShiftCoreTests", dependencies: ["DiscShiftCore"]),
    .testTarget(name: "DiscShiftAppTests", dependencies: ["DiscShift", "DiscShiftCore"])
])
