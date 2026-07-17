import Darwin
import Foundation
import NativeModelConverter

@main
struct NativeModelConverterCLI {
	static func main() async {
		let arguments = CommandLine.arguments.dropFirst()
		guard arguments.count == 2, let input = arguments.first, let output = arguments.last else {
			FileHandle.standardError.write(Data("usage: native-model-converter INPUT.aiagraph OUTPUT.mlmodel\n".utf8))
			exit(64)
		}

		do {
			let package = try await NativeModelGraphPackageReader().read(from: URL(fileURLWithPath: input))
			try NativeModelCoreMLEmitter().emit(package: package, to: URL(fileURLWithPath: output))
			print("Wrote \(output)")
		} catch {
			FileHandle.standardError.write(Data("conversion failed: \(error.localizedDescription)\n".utf8))
			exit(1)
		}
	}
}
