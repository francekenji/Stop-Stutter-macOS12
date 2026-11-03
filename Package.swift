// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "StopStutter",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "StopStutter", targets: ["StopStutter"]),
        .executable(name: "StopStutterHelper", targets: ["StopStutterHelper"])
    ],
    targets: [
        .target(name: "StopStutterCore"),
        .executableTarget(name: "StopStutter", dependencies: ["StopStutterCore"]),
        .executableTarget(name: "StopStutterHelper", dependencies: ["StopStutterCore"]),
        .testTarget(name: "StopStutterCoreTests", dependencies: ["StopStutterCore"])
    ]
)
