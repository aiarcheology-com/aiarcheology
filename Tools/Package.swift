// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "ProjectTool",
    platforms: [.macOS(.v12)],
    dependencies: [
        // 1. Add the ArgumentParser package
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        // SwiftLint CLI (used by local git hooks / tooling via `swift run --package-path Tools swiftlint ...`)
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.0")
    ],
    targets: [
        .executableTarget(
            name: "ProjectTool",
            dependencies: [
                // 2. Depend on the product in your executable target
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)