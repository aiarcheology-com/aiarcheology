import Darwin
import Foundation
import NativeModelConverter

@main
struct NativeModelConverterCLI {
	static func main() async {
		let arguments = Array(CommandLine.arguments.dropFirst())
		if arguments == ["--version"] {
			print("native-model-converter \(NativeModelConverterVersion.packageVersion) conversion-revision \(NativeModelConverterVersion.conversionRevision)")
			return
		}
		guard let invocation = parse(arguments: arguments) else {
			FileHandle.standardError.write(Data("usage: native-model-converter INPUT.aiagraph OUTPUT.mlmodel [--report REPORT.json] | --version\n".utf8))
			exit(64)
		}

		do {
			let outputURL = URL(fileURLWithPath: invocation.output)
			let metrics = try await NativeModelConverter().convert(
				from: URL(fileURLWithPath: invocation.input),
				to: outputURL
			)
			if let report = invocation.report {
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
				try encoder.encode(metrics).write(to: URL(fileURLWithPath: report), options: .atomic)
			}
			let elapsedMilliseconds = Double(metrics.totalConversionDurationNanoseconds) / 1_000_000
			print("Wrote \(invocation.output) in \(String(format: "%.3f", elapsedMilliseconds)) ms (source \(metrics.sourceFootprint.totalByteCount) bytes, model \(metrics.emission.outputModelByteCount) bytes)")
		} catch {
			let outputURL = URL(fileURLWithPath: invocation.output)
			try? FileManager.default.removeItem(at: outputURL)
			try? FileManager.default.removeItem(at: NativeModelMetadataSidecar.url(for: outputURL))
			FileHandle.standardError.write(Data("conversion failed: \(error.localizedDescription)\n".utf8))
			exit(1)
		}
	}

	private static func parse(arguments: [String]) -> (input: String, output: String, report: String?)? {
		switch arguments.count {
		case 2:
			return (arguments[0], arguments[1], nil)
		case 4 where arguments[2] == "--report":
			return (arguments[0], arguments[1], arguments[3])
		default:
			return nil
		}
	}
}
