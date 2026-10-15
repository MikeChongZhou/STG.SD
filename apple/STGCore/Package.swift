// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STGCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "STGCore", targets: ["STGCore"])],
    targets: [
        .target(name: "STGCompression", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "STGCore",
            dependencies: ["STGCompression"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "STGCoreTests", dependencies: ["STGCore", "STGCompression"])
    ]
)
