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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", revision: "53543623fefe68461b7eeea03d7f96677c2fd76d"), // 1.0.4
    ],
    targets: [
        .executableTarget(
            name: "VibeHost",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Argon2Swift", package: "Argon2Swift"),
            ],
            path: "VibeHost",
            exclude: ["Info.plist", "VibeHost.entitlements", "Assets.xcassets", "VibeAppDocument.icns"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "VibeHostTests",
            dependencies: [
                "VibeHost",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "VibeHostTests"
        )
    ]
)
