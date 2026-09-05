// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STGMac",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../apple/STGCore")],
    targets: [
        .executableTarget(
            name: "STGMac",
            dependencies: [.product(name: "STGCore", package: "STGCore")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio"), .linkedFramework("IOKit"), .linkedFramework("Security"), .linkedFramework("ServiceManagement")]
        )
    ],
    swiftLanguageModes: [.v5]
)
