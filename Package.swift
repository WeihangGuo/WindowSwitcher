// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WindowSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "WindowSwitcher",
            path: "Sources/WindowSwitcher"
        )
    ]
)
