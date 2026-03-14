// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeHost",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VibeHost",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "VibeHost",
            exclude: ["Info.plist", "VibeHost.entitlements", "Assets.xcassets", "VibeAppDocument.icns"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "VibeHostTests",
            dependencies: ["VibeHost"],
            path: "VibeHostTests"
        )
    ]
)
