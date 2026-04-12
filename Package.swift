// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandMember",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BandMember",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("MediaToolbox"),
            ]
        )
    ]
)
