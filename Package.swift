// swift-tools-version: 5.9
import PackageDescription
import Foundation

let frameworkRelativePath = "Frameworks/LibTorrent.xcframework"
let hasLibTorrent = FileManager.default.fileExists(atPath: frameworkRelativePath)

var packageTargets: [Target] = [
    .target(
        name: "DM_Reverse_engineering",
        dependencies: hasLibTorrent ? ["LibTorrent"] : [],
        path: "Engine"
    ),
    .executableTarget(
        name: "DM_InterruptionTestCLI",
        dependencies: ["DM_Reverse_engineering"],
        path: "CLI"
    ),
    .testTarget(
        name: "DM_Reverse_engineeringTests",
        dependencies: ["DM_Reverse_engineering"],
        path: "Tests"
    ),
]

if hasLibTorrent {
    packageTargets.append(
        .binaryTarget(
            name: "LibTorrent",
            path: frameworkRelativePath
        )
    )
}

let package = Package(
    name: "DM_Reverse_engineering",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "DM_Reverse_engineering",
            targets: ["DM_Reverse_engineering"]
        ),
    ],
    dependencies: [],
    targets: packageTargets
)
