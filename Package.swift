// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandMember",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.13.0")
    ],
    targets: [
        .executableTarget(
            name: "BandMember",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("MediaToolbox"),
            ]
        )
    ]
)
