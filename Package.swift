// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teachshelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeachshelfCore", targets: ["TeachshelfCore"]),
        .executable(name: "Teachshelf", targets: ["Teachshelf"])
    ],
    targets: [
        .target(name: "TeachshelfCore"),
        .executableTarget(name: "Teachshelf", dependencies: ["TeachshelfCore"]),
        .testTarget(name: "TeachshelfCoreTests", dependencies: ["TeachshelfCore"]),
        .testTarget(name: "TeachshelfLayoutTests", dependencies: ["Teachshelf", "TeachshelfCore"])
    ],
    swiftLanguageModes: [.v5]
)
