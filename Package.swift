// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mitschrift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MitschriftCore", targets: ["MitschriftCore"])
    ],
    targets: [
        .target(
            name: "MitschriftCore",
            path: "Sources/MitschriftCore"
        ),
        .testTarget(
            name: "MitschriftCoreTests",
            dependencies: ["MitschriftCore"],
            path: "Tests/MitschriftCoreTests"
        )
    ]
)
