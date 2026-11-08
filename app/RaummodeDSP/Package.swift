// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RaummodeDSP",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "RaummodeDSP", targets: ["RaummodeDSP"]),
    ],
    targets: [
        .target(
            name: "RaummodeDSP",
            path: "Sources/RaummodeDSP"
        ),
        .testTarget(
            name: "RaummodeDSPTests",
            dependencies: ["RaummodeDSP"],
            path: "Tests/RaummodeDSPTests"
        ),
    ]
)
