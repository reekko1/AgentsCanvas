// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentCanvas",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentCanvas",
            dependencies: ["SwiftTerm"]
        )
    ]
)
