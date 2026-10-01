// swift-tools-version:6.1
// 6.1 is the floor for enabling a dependency's package trait (HeadlessKit's `HeadlessHost`, below;
// Xcode 16.3 or later). `swiftLanguageModes: [.v5]` keeps every target in the Swift 5 language
// mode it had under tools 5.9: moving them to Swift 6 is a separate change.
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
        .package(name: "NativeModelConverter", path: ".."),
        // Headless mode's kit (AIA-0970), in its own private repository since AIA-1005. The app
        // pins the same exact version in the Xcode project, and ProjectToolCoreTests fails when the
        // manifests or the three Package.resolved files (Tools, the workspace, the project)
        // disagree, so the tool and the app speak one wire protocol.
        // Resolving it needs GitHub credentials for git over HTTPS (`gh auth setup-git`).
        // Since 0.2.0 the kit compiles only under `DEBUG || HeadlessHost`, so an app's Release build
        // carries none of it (AIA-1006). ProjectTool is a host: the trait keeps the client and the
        // runner in a `-c release` build, and since 1.0.0 the simulator launcher behind `headless`
        // (AIA-1008). The app must never enable it.
        .package(url: "https://github.com/aiarcheology-com/HeadlessKit.git", exact: "1.0.0-rc.3", traits: ["HeadlessHost"])
    ],
    targets: [
        // Pure, testable logic. A test target cannot `@testable import` an executable target,
        // so anything worth asserting on lives here rather than in ProjectTool itself.
        .target(
            name: "ProjectToolCore",
            dependencies: [
                .product(name: "HeadlessKit", package: "HeadlessKit"),
                // ML Browser's `HeadlessProject`: what the kit's host tooling needs to know about the app.
                .product(name: "HeadlessSimulatorLauncher", package: "HeadlessKit")
            ]
        ),
        .executableTarget(
            name: "ProjectTool",
            dependencies: [
                "ProjectToolCore",
                // 2. Depend on the product in your executable target
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SupportLogFormat", package: "NativeModelConverter"),
                // Headless mode's tooling (AIA-0970): the kit's `headless` commands, from the same
                // pinned HeadlessKit version the app links (see the dependency above).
                .product(name: "HeadlessSimulatorLauncher", package: "HeadlessKit")
            ]
        ),
        .testTarget(
            name: "ProjectToolCoreTests",
            dependencies: [
                "ProjectToolCore",
                .product(name: "HeadlessKit", package: "HeadlessKit"),
                .product(name: "HeadlessScenario", package: "HeadlessKit"),
                .product(name: "HeadlessSimulatorLauncher", package: "HeadlessKit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
