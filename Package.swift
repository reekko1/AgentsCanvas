// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentCanvas",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentCanvas",
            dependencies: ["SwiftTerm", "Sparkle"],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/backdrop-dark.mp4"),
                .copy("Resources/backdrop-light.mp4")
            ]
        )
    ]
)
