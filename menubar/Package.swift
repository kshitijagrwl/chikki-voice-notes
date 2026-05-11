// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChikkiApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ChikkiApp",
            dependencies: ["KeyboardShortcuts", "Yams"],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
