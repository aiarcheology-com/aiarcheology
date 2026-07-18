import CoreML
import Darwin
import Foundation

private struct EvaluationManifest: Encodable {
	let evaluations: [Evaluation]

	struct Evaluation: Encodable {
		let inputIndex: Int
		let outputs: [Output]
	}

	struct Output: Encodable {
		let name: String
		let shape: [Int]
		let file: String
	}
}

@main
struct NativeModelEvaluatorCLI {
	static func main() {
		let arguments = CommandLine.arguments.dropFirst()
		guard arguments.count >= 3, let modelPath = arguments.first, let outputPath = arguments.dropFirst().first else {
			FileHandle.standardError.write(Data("usage: native-model-evaluator MODEL.mlmodel OUTPUT_DIRECTORY INPUT1.f32 [INPUT2.f32 ...]\\n".utf8))
			exit(64)
		}
		let inputPaths = arguments.dropFirst(2)

			do {
			let modelURL = URL(fileURLWithPath: modelPath)
			let compiledURL = try MLModel.compileModel(at: modelURL)
			defer { try? FileManager.default.removeItem(at: compiledURL) }
			let configuration = MLModelConfiguration()
			configuration.computeUnits = .cpuOnly
			let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
			guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
				let constraint = input.value.multiArrayConstraint
			else {
				throw EvaluationError.missingMultiArrayInput
			}

			let shape = constraint.shape.map { $0.intValue }
			let inputElementCount = try elementCount(for: shape)
			// Guard the element-count-to-byte-count multiplication so a pathological shape reports an
			// invalid shape rather than trapping on Int overflow.
			let (inputByteCount, byteCountOverflow) = inputElementCount.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
			guard !byteCountOverflow else {
				throw EvaluationError.invalidShape(shape)
			}
			let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
			try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
			var evaluations: [EvaluationManifest.Evaluation] = []
			for (inputIndex, inputPath) in inputPaths.enumerated() {
				let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
				guard inputData.count == inputByteCount else {
					throw EvaluationError.inputByteCount(expected: inputByteCount, actual: inputData.count)
				}
				let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
				for index in 0..<inputElementCount {
					let bits = inputData.withUnsafeBytes { bytes in
						UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self))
					}
					array[index] = NSNumber(value: Float(bitPattern: bits))
				}

				let provider = try MLDictionaryFeatureProvider(dictionary: [input.key: array])
				let prediction = try model.prediction(from: provider)
				let evaluationDirectory = outputDirectory.appendingPathComponent("input-\(inputIndex)", isDirectory: true)
				try FileManager.default.createDirectory(at: evaluationDirectory, withIntermediateDirectories: false)
				var outputs: [EvaluationManifest.Output] = []
				for (outputIndex, name) in prediction.featureNames.sorted().enumerated() {
					guard let output = prediction.featureValue(for: name)?.multiArrayValue else {
						throw EvaluationError.nonMultiArrayOutput(name)
					}
					let outputShape = output.shape.map { $0.intValue }
					let outputCount = try elementCount(for: outputShape)
					var values = [Float](repeating: 0, count: outputCount)
					for valueIndex in 0..<outputCount {
						values[valueIndex] = output[valueIndex].floatValue
					}
					let file = "output-\(outputIndex).f32"
					try values.withUnsafeBytes { bytes in
						try Data(bytes).write(to: evaluationDirectory.appendingPathComponent(file), options: .atomic)
					}
					outputs.append(.init(name: name, shape: outputShape, file: file))
				}
				evaluations.append(.init(inputIndex: inputIndex, outputs: outputs))
			}
			try JSONEncoder().encode(EvaluationManifest(evaluations: evaluations)).write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
		} catch {
			FileHandle.standardError.write(Data("evaluation failed: \(error.localizedDescription)\\n".utf8))
			exit(1)
		}
	}

	private static func elementCount(for shape: [Int]) throws -> Int {
		guard !shape.isEmpty else { throw EvaluationError.invalidShape(shape) }
		return try shape.reduce(1) { count, dimension in
			guard dimension > 0 else { throw EvaluationError.invalidShape(shape) }
			let (next, overflow) = count.multipliedReportingOverflow(by: dimension)
			guard !overflow else { throw EvaluationError.invalidShape(shape) }
			return next
		}
	}
}

private enum EvaluationError: LocalizedError {
	case missingMultiArrayInput
	case inputByteCount(expected: Int, actual: Int)
	case invalidShape([Int])
	case nonMultiArrayOutput(String)

	var errorDescription: String? {
		switch self {
		case .missingMultiArrayInput:
			"Model must have one MLMultiArray input."
		case .inputByteCount(let expected, let actual):
			"Input contains \(actual) bytes; expected \(expected) Float32 bytes."
		case .invalidShape(let shape):
			"Model has an invalid or oversized tensor shape: \(shape)."
		case .nonMultiArrayOutput(let name):
			"Model output '\(name)' is not an MLMultiArray."
		}
	}
}
