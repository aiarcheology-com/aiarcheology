// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "NativeModelConverter",
	platforms: [
		.iOS(.v17),
		.macOS(.v14)
	],
	products: [
		.library(name: "NativeModelConverter", targets: ["NativeModelConverter"]),
		// Independent of the converter, and deliberately its own product rather than a folder
		// inside one: the iOS app seals support logs with it and `ProjectTool support-log`
		// opens them, so it must be reachable from both without dragging the converter along.
		// It lives in this package rather than a new one only because the app already
		// references this directory (`relativePath = ..`), and a second local package nested
		// inside the first is a package-resolution risk not worth taking for a naming
		// preference. See AIA-0643.
		.library(name: "SupportLogFormat", targets: ["SupportLogFormat"]),
		// Drive an app through screens and actions without its UI (AIA-0970). App-agnostic and
		// dependency-free on purpose: ML Browser is only the first adopter, and another SwiftUI app
		// must be able to take these three products without anything from this repository. They
		// live here for the same resolution reason as SupportLogFormat above; moving them to their
		// own repository later changes no code.
		.library(name: "HeadlessKit", targets: ["HeadlessKit"]),
		.library(name: "HeadlessKitTransport", targets: ["HeadlessKitTransport"]),
		.library(name: "HeadlessScenario", targets: ["HeadlessScenario"]),
		.executable(name: "native-model-converter", targets: ["NativeModelConverterCLI"]),
		.executable(name: "native-model-evaluator", targets: ["NativeModelEvaluatorCLI"]),
		// Local evidence runner for the real ADAF detector. It intentionally exercises the emitted
		// detector pipeline but is not imported by the app's host-side chunk loop.
		.executable(name: "adaf-detector-parity-runner", targets: ["ADAFDetectorParityRunner"])
	],
	targets: [
		.target(name: "NativeModelConverter"),
		.target(name: "SupportLogFormat"),
		.target(name: "HeadlessKit"),
		.target(name: "HeadlessKitTransport", dependencies: ["HeadlessKit"]),
		.target(name: "HeadlessScenario", dependencies: ["HeadlessKit"]),
		.executableTarget(name: "NativeModelConverterCLI", dependencies: ["NativeModelConverter"]),
		.executableTarget(name: "NativeModelEvaluatorCLI"),
		.executableTarget(name: "ADAFDetectorParityRunner", dependencies: ["NativeModelConverter"]),
		.testTarget(
			name: "NativeModelConverterTests",
			dependencies: ["NativeModelConverter"],
			resources: [.process("Fixtures")]
		),
		.testTarget(
			name: "SupportLogFormatTests",
			dependencies: ["SupportLogFormat"]
		),
		.testTarget(
			name: "HeadlessKitTests",
			dependencies: ["HeadlessKit", "HeadlessKitTransport", "HeadlessScenario"]
		)
	]
)
