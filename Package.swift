// swift-tools-version: 5.9
import PackageDescription
import Foundation

let frameworkRelativePath = "Frameworks/LibTorrent.xcframework"
let hasLibTorrent = FileManager.default.fileExists(atPath: frameworkRelativePath)

let vlcFrameworkRelativePath = "Frameworks/VLCKit.xcframework"
let hasVLCKit = FileManager.default.fileExists(atPath: vlcFrameworkRelativePath)

var engineDependencies: [Target.Dependency] = []
if hasLibTorrent {
    engineDependencies.append("LibTorrent")
}
if hasVLCKit {
    engineDependencies.append("VLCKit")
}

var packageTargets: [Target] = [
    .target(
        name: "DownloadEngineKit",
        dependencies: engineDependencies,
        path: "Engine"
    ),
    .executableTarget(
        name: "DownloadInterruptionCLI",
        dependencies: ["DownloadEngineKit"],
        path: "CLI"
    ),
    .testTarget(
        name: "DownloadEngineKitTests",
        dependencies: ["DownloadEngineKit"],
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

if hasVLCKit {
    packageTargets.append(
        .binaryTarget(
            name: "VLCKit",
            path: vlcFrameworkRelativePath
        )
    )
}

let package = Package(
    name: "SwiftDownloadEngine",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "DownloadEngineKit",
            targets: ["DownloadEngineKit"]
        ),
    ],
    dependencies: [],
    targets: packageTargets
)
