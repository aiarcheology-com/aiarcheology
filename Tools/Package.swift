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
        //
        // `name:` is load-bearing, not decoration. Without it SwiftPM derives the package identity
        // from the directory name, so `.product(package:)` below would have to hard-code
        // "aiarcheology" — and every checkout under a different folder name would fail to resolve.
        // That is not hypothetical for this repo: ci_post_clone.sh runs
        // `swift run --package-path Tools ProjectTool setup` on every Xcode Cloud action, against
        // a clone whose directory name we do not control.
        .package(name: "NativeModelConverter", path: "..")
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
                .product(name: "SupportLogFormat", package: "NativeModelConverter")
            ]
        ),
        .testTarget(
            name: "ProjectToolCoreTests",
            dependencies: ["ProjectToolCore"]
        )
    ]
)
