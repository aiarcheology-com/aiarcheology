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
		.executable(name: "native-model-converter", targets: ["NativeModelConverterCLI"]),
		.executable(name: "native-model-evaluator", targets: ["NativeModelEvaluatorCLI"])
	],
	targets: [
		.target(name: "NativeModelConverter"),
		.target(name: "SupportLogFormat"),
		.executableTarget(name: "NativeModelConverterCLI", dependencies: ["NativeModelConverter"]),
		.executableTarget(name: "NativeModelEvaluatorCLI"),
		.testTarget(
			name: "NativeModelConverterTests",
			dependencies: ["NativeModelConverter"],
			resources: [.process("Fixtures")]
		),
		.testTarget(
			name: "SupportLogFormatTests",
			dependencies: ["SupportLogFormat"]
		)
	]
)
