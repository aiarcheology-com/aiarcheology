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
		if arguments.first == "inspect-checkpoint" {
			guard arguments.count == 2 else {
				FileHandle.standardError.write(Data("usage: native-model-converter inspect-checkpoint CHECKPOINT\n".utf8))
				exit(64)
			}
			inspectCheckpoint(at: arguments[1])
			return
		}
		guard let invocation = parse(arguments: arguments) else {
			FileHandle.standardError.write(Data("usage: native-model-converter INPUT.aiagraph OUTPUT.mlmodel [--report REPORT.json] | inspect-checkpoint CHECKPOINT | --version\n".utf8))
			exit(64)
		}

		let outputURL = URL(fileURLWithPath: invocation.output)
		let sidecarURL = NativeModelMetadataSidecar.url(for: outputURL)
		// A report path that collides with the model or its sidecar would overwrite a conversion
		// artifact. Reject it up front rather than after writing the model.
		if let report = invocation.report {
			let reportURL = URL(fileURLWithPath: report).standardizedFileURL
			if reportURL == outputURL.standardizedFileURL || reportURL == sidecarURL.standardizedFileURL {
				FileHandle.standardError.write(
					Data("report path must differ from the output model and its metadata sidecar\n".utf8)
				)
				exit(64)
			}
		}
		// Only clean artifacts this invocation created. Deleting a pre-existing file at the output
		// path on failure would destroy an unrelated user file the converter never wrote.
		let outputPreexisted = FileManager.default.fileExists(atPath: outputURL.path)
		let sidecarPreexisted = FileManager.default.fileExists(atPath: sidecarURL.path)
		do {
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
			if !outputPreexisted {
				try? FileManager.default.removeItem(at: outputURL)
			}
			if !sidecarPreexisted {
				try? FileManager.default.removeItem(at: sidecarURL)
			}
			FileHandle.standardError.write(Data("conversion failed: \(error.localizedDescription)\n".utf8))
			exit(1)
		}
	}

	/// Reports what a PyTorch checkpoint describes itself as, without converting anything.
	///
	/// Exists so the reader can be pointed at a file nobody here produced — a fresh download rather
	/// than a committed fixture. It reads the same four things the app does (the archive's end
	/// records, its central directory, `data.pkl` and `version`), so the byte count it prints is the
	/// real cost of identifying a half-gigabyte checkpoint.
	private static func inspectCheckpoint(at path: String) {
		let url = URL(fileURLWithPath: path)
		let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
		do {
			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: url)
			print("file            \(url.lastPathComponent)\(size.map { " (\($0) bytes)" } ?? "")")
			print("archive root    \(checkpoint.root)  (torch.save format \(checkpoint.formatVersion))")
			print("state_dict      \(checkpoint.tensors.count) tensors, "
				+ "\(checkpoint.tensors.reduce(0) { $0 + $1.elementCount }) parameters")
			print("storages        \(checkpoint.totalStorageCount) total, "
				+ "\(checkpoint.totalStorageCount - checkpoint.tensors.count) of them optimizer state (never read)")
			if let identifier = checkpoint.identifier { print("training id     \(identifier)") }
			if let epoch = checkpoint.epoch { print("epoch           \(epoch)") }

			switch ADAFCheckpointCatalog.identity(of: checkpoint) {
			case .objectDetection(let model):
				print("identified as   ADAF object detection — \(model.architecture)")
				print("                detects \(model.detectableClassCount) class "
					+ "(\(model.predictorLogitCount) predictor logits, including background)")
				print("                label: \(model.classLabel?.displayName ?? "none")"
					+ " (\(model.labelProvenance.rawValue))")
				print("conversion      not implemented yet — that is AIA-0654 M3")
			case .segmentation(let architecture):
				print("identified as   semantic segmentation — \(architecture)")
				print("conversion      not supported, and not planned: this app detects and classifies")
				print("                objects in a scene and has no representation for a pixel mask")
			case .unrecognized(let summary):
				print("identified as   not a recognised ADAF model")
				print("                \(summary.tensorCount) tensors, top-level keys: "
					+ summary.topLevelPrefixes.joined(separator: ", "))
				if let family = summary.architectureFamily { print("                looks like \(family)") }
			}
		} catch {
			FileHandle.standardError.write(Data("could not read \(url.lastPathComponent): \(error)\n".utf8))
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
