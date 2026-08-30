// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STGCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "STGCore", targets: ["STGCore"])],
    targets: [
        .target(
            name: "STGCore",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "STGCoreTests", dependencies: ["STGCore"])
    ]
)
