//
//  NativeModelEmissionRegressionTests.swift
//  NativeModelConverterTests
//
//  Two questions this revision has to answer: does every artifact carry the bumped conversion
//  revision, and did adding the two-stage detector operations, the artifact manifest and the parity
//  provenance move anything in the conversions that already worked?
//
//  The second question is deliberately asked of the DECODED structure, never of the bytes. The
//  revision stamp is inside the emitted metadata, so a byte-for-byte comparison against the previous
//  revision is guaranteed to differ and would prove nothing. What must not differ is the model a
//  runtime sees: the specification version, the declared interface, and the layer sequence.
//

import CoreML
import CryptoKit
import XCTest
@testable import NativeModelConverter

final class NativeModelEmissionRegressionTests: XCTestCase {

	/// The revision is a promise to a consumer that the emitted artifact changed, so the value is
	/// pinned as a literal here: bumping it stays a deliberate edit, and an emitter change that
	/// forgets it fails rather than shipping new bytes under an old revision.
	///
	/// ``NativeModelGraphPackageTests`` already proves the stamp reaches a compiled model on the
	/// package path; what it cannot prove — it compares against the constant itself — is that the
	/// constant advanced.
	func testConversionRevision_isTheCurrentValueAndIsStampedIntoTheEmittedModel() throws {
		XCTAssertEqual(NativeModelConverterVersion.conversionRevision, 8)

		let userDefined = try emitAndReadUserDefined()
		XCTAssertEqual(userDefined["com.aiarcheology.native.converter.conversion-revision"], "8")
		XCTAssertEqual(userDefined["com.aiarcheology.native.converter.package-version"], "0.1.0")
	}

	/// Converts a graph of the kind that already converted before this revision and asserts the
	/// emitted model decodes to exactly the structure it did before: same specification version, same
	/// input and output features, same layer sequence with the same Core ML layer types, and the same
	/// parameter payload behind each of those types.
	///
	/// The payload digests are the difference between comparing the model and comparing its outline:
	/// a convolution's padding, stride and kernel, a pooling layer's mode, the preprocessing constants
	/// — every one of them changes bytes that no name, wiring or field number reports.
	///
	/// The expected structure is a literal recorded from the previous revision's output, the payload
	/// digests included: they were taken by running this decoding against the emitter as it stood
	/// before this branch, so they assert equality with that revision rather than with this one. It
	/// excludes the model description's metadata block — that is where the intentional changes live
	/// (the revision stamp, the parity provenance) — and nothing else.
	func testRepresentativeConversion_decodesToTheStructureOfThePreviousRevision() throws {
		XCTAssertEqual(try emittedStructure(), [
			"specificationVersion=4",
			"input image type=4 f1=2,f2=2,f3=20",
			"output classLabel type=3",
			"output classLabelProbs type=6",
			"predictedFeatureName=classLabel",
			"predictedProbabilitiesName=classLabelProbs",
			"network f5=1,f6=1",
			"network labels=[red, green, blue]",
			"network labelProbabilityLayerName=output__classProbs",
			"layer image_preprocessing in=[image] out=[input] type=245 params=c3bceef1",
			"layer features in=[input] out=[features] type=100 params=0c210b44",
			"layer activation in=[features] out=[activated] type=130 params=4f82d2d4",
			"layer pool in=[activated] out=[pooled] type=120 params=e46ce086",
			"layer flatten in=[pooled] out=[output] type=1130 params=fb8da7eb",
			"layer classifier_softmax in=[output] out=[output__classProbs] type=950 params=fb8da7eb"
		])
	}

	// MARK: - The representative graph

	/// A 3-channel image classifier: image preprocessing, a weight-bearing convolution, an activation,
	/// a pooling layer, a flatten and the classifier's own softmax head — one graph covering every
	/// emitter branch an existing conversion uses, and no operation this revision introduced.
	private func representativeGraph() -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 3, 2, 2])],
			weights: [
				NativeModelWeight(name: "kernel", dataType: .float32, shape: [3, 3, 1, 1], offset: 0, byteCount: 36),
				NativeModelWeight(name: "bias", dataType: .float32, shape: [3], offset: 36, byteCount: 12)
			],
			operations: [
				NativeModelOperation(
					name: "features",
					kind: .convolution2D,
					inputs: ["input", "kernel", "bias"],
					outputs: [NativeModelTensor(name: "features", dataType: .float32, shape: [1, 3, 2, 2])],
					attributes: [
						"kernelSize": .integers([1, 1]),
						"strides": .integers([1, 1]),
						"padding": .integers([0, 0]),
						"dilations": .integers([1, 1]),
						"groups": .integer(1)
					]
				),
				NativeModelOperation(
					name: "activation",
					kind: .relu,
					inputs: ["features"],
					outputs: [NativeModelTensor(name: "activated", dataType: .float32, shape: [1, 3, 2, 2])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "pool",
					kind: .globalAveragePool2D,
					inputs: ["activated"],
					outputs: [NativeModelTensor(name: "pooled", dataType: .float32, shape: [1, 3, 1, 1])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "flatten",
					kind: .flatten,
					inputs: ["pooled"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 3])],
					attributes: ["axis": .integer(1)]
				)
			],
			outputs: ["output"]
		)
	}

	private func emit() throws -> URL {
		let modelURL = try temporaryDirectory().appendingPathComponent("representative.mlmodel")
		let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
		try NativeModelCoreMLEmitter().emit(
			graph: representativeGraph(),
			weights: (identity + [0, 0, 0]).withUnsafeBytes { Data($0) },
			to: modelURL,
			classifierLabels: ["red", "green", "blue"],
			imagePreprocessing: .imageNetRGB
		)
		return modelURL
	}

	/// Reads the stamp the way a consumer does: off a compiled model's description, not off the
	/// emitter's own intermediate values.
	private func emitAndReadUserDefined() throws -> [String: String] {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let compiledURL = try MLModel.compileModel(at: try emit())
		addTeardownBlock { try? FileManager.default.removeItem(at: compiledURL) }
		let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
		return model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
	}

	// MARK: - Structural decoding

	/// Decodes the emitted protobuf into the facts a runtime depends on, in emission order. Read
	/// straight off the written bytes rather than through `MLModel`, because `MLModel` publishes the
	/// interface but not the layer sequence — and the layer sequence is what an IR or emitter change
	/// would perturb.
	private func emittedStructure() throws -> [String] {
		let model = try ProtobufReader.fields(in: try Data(contentsOf: try emit()))
		var structure: [String] = []
		structure.append("specificationVersion=\(try XCTUnwrap(model.firstVarint(1)))")

		let description = try ProtobufReader.fields(in: try XCTUnwrap(model.firstBytes(2)))
		for feature in description.allBytes(1) {
			structure.append("input \(try featureStructure(feature))")
		}
		for feature in description.allBytes(10) {
			structure.append("output \(try featureStructure(feature))")
		}
		if let predicted = description.firstString(11) {
			structure.append("predictedFeatureName=\(predicted)")
		}
		if let probabilities = description.firstString(12) {
			structure.append("predictedProbabilitiesName=\(probabilities)")
		}
		// Field 100 is the metadata block: intentionally changed by this revision, so it is the one
		// part of the description this comparison must not look at.

		// A classifier travels in field 403, a plain network in field 500.
		let network = try ProtobufReader.fields(
			in: try XCTUnwrap(model.firstBytes(403) ?? model.firstBytes(500))
		)
		let mappings = varintStructure(of: network)
		if !mappings.isEmpty { structure.append("network \(mappings)") }
		if let labels = network.firstBytes(100) {
			let names = try ProtobufReader.fields(in: labels).allBytes(1).map { try utf8($0) }
			structure.append("network labels=[\(names.joined(separator: ", "))]")
		}
		if let probabilityLayer = network.firstString(200) {
			structure.append("network labelProbabilityLayerName=\(probabilityLayer)")
		}
		for layer in network.allBytes(1) {
			structure.append("layer \(try layerStructure(layer))")
		}
		return structure
	}

	private func featureStructure(_ feature: Data) throws -> String {
		let fields = try ProtobufReader.fields(in: feature)
		let name = try XCTUnwrap(fields.firstString(1))
		let type = try ProtobufReader.fields(in: try XCTUnwrap(fields.firstBytes(3)))
		// The feature type is a union: its single set field number IS the kind (3 string, 4 image,
		// 5 multi-array, 6 dictionary), and its varints are the shape or the image geometry.
		let kind = try XCTUnwrap(type.map(\.field).first)
		let values = varintStructure(of: try ProtobufReader.fields(in: try XCTUnwrap(type.firstBytes(kind))))
		return values.isEmpty ? "\(name) type=\(kind)" : "\(name) type=\(kind) \(values)"
	}

	private func layerStructure(_ layer: Data) throws -> String {
		let fields = try ProtobufReader.fields(in: layer)
		let name = try XCTUnwrap(fields.firstString(1))
		let inputs = try fields.allBytes(2).map { try utf8($0) }
		let outputs = try fields.allBytes(3).map { try utf8($0) }
		// The layer parameters are a union too, and its field number is the Core ML layer type — the
		// fact that says a convolution is still a convolution and not, say, an inner product.
		let kind = try XCTUnwrap(fields.map(\.field).first { $0 >= 100 })
		// The type alone is not the layer, though: padding, stride, kernel size, pooling mode and the
		// preprocessing constants all live inside the parameter payload, where a change moves no name,
		// no wiring and no field number. Digesting those bytes is what makes this a comparison of the
		// emitted model rather than of its outline.
		let parameters = try XCTUnwrap(fields.firstBytes(kind))
		return "\(name) in=[\(inputs.joined(separator: ", "))] out=[\(outputs.joined(separator: ", "))]"
			+ " type=\(kind) params=\(digest(parameters))"
	}

	/// A truncated SHA-256 of a parameter payload. Short because the expectation above is a literal a
	/// person reads and re-records; four bytes still make a collision with an altered payload far less
	/// likely than the mistake this test exists to catch.
	private func digest(_ payload: Data) -> String {
		SHA256.hash(data: payload).prefix(4).map { String(format: "%02x", $0) }.joined()
	}

	/// Blob names are protobuf strings; anything that does not decode as UTF-8 is a decoding mistake in
	/// this test, not a structure worth comparing.
	private func utf8(_ data: Data) throws -> String {
		try XCTUnwrap(String(bytes: data, encoding: .utf8))
	}

	/// Renders a message's own varint fields in emission order, so a reordered or retyped scalar shows
	/// up as a difference rather than being averaged away.
	private func varintStructure(of fields: [(field: Int, value: ProtobufValue)]) -> String {
		fields.compactMap { field in
			guard case .varint(let value) = field.value else { return nil }
			return "f\(field.field)=\(value)"
		}
		.joined(separator: ",")
	}

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return directory
	}
}
