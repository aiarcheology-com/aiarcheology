// swift-tools-version:5.9
import PackageDescription

// Deliberately dependency-free: the point of this harness is to observe what Apple's own
// Vision stack does to a detector's output, so anything it links that the app does not link
// would be a difference the measurement cannot account for.
let package = Package(
    name: "VisionReplay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VisionReplay", path: "Sources/VisionReplay")
    ]
)
