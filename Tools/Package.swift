// swift-tools-version:5.9
// 5.9 is the floor for `.macOS(.v14)` below; deliberately not 6.0, which would switch the existing
// targets to the Swift 6 language mode and is a change this ticket has no reason to make.
import PackageDescription

let package = Package(
    name: "ProjectTool",
    // macOS 14 is HPKE's floor, required by SupportLogFormat (AIA-0643). This manifest is on the
    // critical path of every Xcode Cloud action — ci_post_clone.sh runs `ProjectTool setup` before
    // any build — so the bump raises the floor for CI, not just for a developer convenience.
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        // The sealed support-log format, shared with the iOS app so the sealer and the opener
        // cannot drift apart. See Sources/SupportLogFormat.
        .package(path: "..")
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // `aiarcheology`, not `NativeModelConverter`: a path dependency's identity is the
                // directory name, not the name declared in its manifest.
                .product(name: "SupportLogFormat", package: "aiarcheology")
            ]
        ),
        .testTarget(
            name: "ProjectToolCoreTests",
            dependencies: ["ProjectToolCore"]
        )
    ]
)
