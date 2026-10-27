// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBackupChecker",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .executableTarget(
            name: "PhotoBackupChecker",
            dependencies: ["Core"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ImageCaptureCore"), .linkedFramework("AVKit")]  // AVKit: SwiftUI VideoPlayer aborts if it isn't loaded up front
        ),
        .executableTarget(name: "SelfTest", dependencies: ["Core"]),
    ]
)
