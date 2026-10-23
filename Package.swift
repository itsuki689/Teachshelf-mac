// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teachshelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeachshelfCore", targets: ["TeachshelfCore"]),
        .executable(name: "Teachshelf", targets: ["Teachshelf"]),
        .executable(name: "TeachshelfMCP", targets: ["TeachshelfMCP"])
    ],
    targets: [
        .target(name: "TeachshelfCore"),
        .target(name: "TeachshelfMCPKit", dependencies: ["TeachshelfCore"]),
        .executableTarget(name: "TeachshelfMCP", dependencies: ["TeachshelfMCPKit"]),
        .executableTarget(name: "Teachshelf", dependencies: ["TeachshelfCore", "TeachshelfMCPKit"]),
        .testTarget(name: "TeachshelfMCPTests", dependencies: ["TeachshelfMCPKit", "TeachshelfCore"]),
        .testTarget(name: "TeachshelfCoreTests", dependencies: ["TeachshelfCore"]),
        .testTarget(name: "TeachshelfLayoutTests", dependencies: ["Teachshelf", "TeachshelfCore"])
    ],
    swiftLanguageModes: [.v5]
)
