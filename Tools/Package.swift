// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "ProjectTool",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0")
    ],
    targets: [
        // Pure, testable logic. A test target cannot `@testable import` an executable target,
        // so anything worth asserting on lives here rather than in ProjectTool itself.
        .target(name: "ProjectToolCore"),
        .executableTarget(
            name: "ProjectTool",
            dependencies: [
                "ProjectToolCore",
                // 2. Depend on the product in your executable target
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ProjectToolCoreTests",
            dependencies: ["ProjectToolCore"]
        )
    ]
)