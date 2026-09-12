// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExplorerLink",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ExplorerLinkCore", targets: ["ExplorerLinkCore"]),
        .library(name: "ExplorerFlashCore", targets: ["ExplorerFlashCore"])
    ],
    targets: [
        .target(name: "ExplorerLinkCore"),
        .target(name: "ExplorerFlashCore", dependencies: ["ExplorerLinkCore"]),
        .testTarget(name: "ExplorerLinkCoreTests", dependencies: ["ExplorerLinkCore"]),
        .testTarget(name: "ExplorerFlashCoreTests", dependencies: ["ExplorerFlashCore"])
    ]
)
