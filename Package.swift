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
		.executable(name: "native-model-converter", targets: ["NativeModelConverterCLI"])
	],
	targets: [
		.target(name: "NativeModelConverter"),
		.executableTarget(name: "NativeModelConverterCLI", dependencies: ["NativeModelConverter"]),
		.testTarget(
			name: "NativeModelConverterTests",
			dependencies: ["NativeModelConverter"],
			resources: [.process("Fixtures")]
		)
	]
)
