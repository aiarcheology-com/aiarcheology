//
//  NativeModelEmittedArtifactsTests.swift
//  NativeModelConverterTests
//

import CoreML
import CryptoKit
import XCTest
@testable import NativeModelConverter

final class NativeModelEmittedArtifactsTests: XCTestCase {

	func testEmitWithROIBoxHeadChunk_writesTwoIndependentlyLoadableModels() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		let artifacts = try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL, roiBoxHeadChunk: chunk()
		)

		XCTAssertEqual(artifacts.primary.role, .primary)
		XCTAssertEqual(artifacts.primary.url, modelURL)
		let companion = try XCTUnwrap(artifacts.companions.first)
		XCTAssertEqual(artifacts.companions.count, 1)
		XCTAssertEqual(companion.role, .roiBoxHeadChunk)
		XCTAssertEqual(companion.url, directory.appendingPathComponent("converted.roi-box-head-chunk.mlmodel"))

		// Two standalone models, not one pipeline: each compiles and predicts on its own, which a
		// pipeline stage embedded in the primary could never do.
		let primary = try compiled(at: artifacts.primary.url)
		let primaryOutput = try predict(primary, feature: "input", shape: [1, 3, 2, 2], values: [Float](repeating: -1, count: 12))
		XCTAssertEqual(primaryOutput.count, 12)
		XCTAssertEqual(primaryOutput.allSatisfy { $0 == 0 }, true, "ReLU of a negative input is zero.")

		let chunkModel = try compiled(at: companion.url)
		var proposals = [Float](repeating: -2, count: 52 * 4)
		proposals[0] = 7
		let chunkOutput = try predict(chunkModel, feature: "proposal_features", shape: [52, 4, 1, 1], values: proposals)
		XCTAssertEqual(chunkOutput.count, 52 * 4)
		// Identity projection plus offsets [1, 2, 3, 4], applied to every proposal in the batch.
		XCTAssertEqual(chunkOutput[0], 8, accuracy: 0.000_01)
		XCTAssertEqual(chunkOutput[1], 0, accuracy: 0.000_01)
		XCTAssertEqual(chunkOutput[3], 2, accuracy: 0.000_01)
		XCTAssertEqual(chunkOutput[52 * 4 - 1], 2, accuracy: 0.000_01, "The last proposal in the fixed batch is projected too.")

		XCTAssertEqual(artifacts.primary.byteCount, try fileByteCount(at: artifacts.primary.url))
		XCTAssertEqual(companion.byteCount, try fileByteCount(at: companion.url))
	}

	func testEmitWithROIBoxHeadChunk_manifestOnThePrimaryMatchesTheCompanionOnDisk() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		let artifacts = try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL, roiBoxHeadChunk: chunk()
		)

		// Read the manifest the way a runtime would: off the loaded model's description, not by
		// re-parsing the protobuf the emitter just wrote.
		let json = try XCTUnwrap(userDefined(of: try compiled(at: modelURL))[NativeModelArtifactManifest.userDefinedKey])
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		XCTAssertEqual(object["format"] as? String, "com.aiarcheology.native-model-artifacts")
		XCTAssertEqual(object["formatVersion"] as? Int, 1)

		let manifest = try JSONDecoder().decode(NativeModelArtifactManifest.self, from: Data(json.utf8))
		let recorded = try XCTUnwrap(manifest.companions.first)
		XCTAssertEqual(manifest.companions.count, 1)
		XCTAssertEqual(recorded.role, .roiBoxHeadChunk)
		XCTAssertEqual(recorded.filename, "converted.roi-box-head-chunk.mlmodel")
		XCTAssertEqual(recorded.fixedBatchSize, 52)
		XCTAssertEqual(recorded.proposalCount, 1000)
		XCTAssertEqual(recorded.invocationCount, 20)

		// The filename must resolve beside the primary, and the digest must be of the bytes actually
		// sitting there — hashed here independently, so an emitter that recorded the wrong buffer
		// (its own weights, the primary's bytes) cannot pass by agreeing with itself.
		let resolved = modelURL.deletingLastPathComponent().appendingPathComponent(recorded.filename)
		let onDisk = SHA256.hash(data: try Data(contentsOf: resolved)).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(recorded.sha256, onDisk)
		XCTAssertEqual(artifacts.companions.first?.sha256, onDisk)
		XCTAssertNotEqual(recorded.sha256, artifacts.primary.sha256)
	}

	func testEmitWithROIBoxHeadChunk_invocationCountIsDerivedFromTheBatchSize() throws {
		// A hardcoded 20 survives the 1000/52 case and nothing else; a truncating division loses the
		// tail batch that carries the last 12 proposals.
		XCTAssertEqual(try recordedInvocationCount(fixedBatchSize: 52, proposalCount: 1000), 20)
		XCTAssertEqual(try recordedInvocationCount(fixedBatchSize: 52, proposalCount: 104), 2)
		XCTAssertEqual(try recordedInvocationCount(fixedBatchSize: 52, proposalCount: 1), 1)
		XCTAssertEqual(try recordedInvocationCount(fixedBatchSize: 1, proposalCount: 300), 300)
	}

	func testEmitWithROIBoxHeadChunk_companionCarriesItsOwnMetadataNotACopyOfThePrimarys() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		let artifacts = try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL, roiBoxHeadChunk: chunk()
		)

		let primaryMetadata = userDefined(of: try compiled(at: modelURL))
		let companionMetadata = userDefined(of: try compiled(at: try XCTUnwrap(artifacts.companions.first).url))

		// The companion's declared interface is its own [52, 4, 1, 1] proposal batch, so a metadata
		// block copied from the primary would describe a model this file is not.
		let companionInterface = try XCTUnwrap(companionMetadata["com.aiarcheology.native.target.interface.json"])
		XCTAssertNotEqual(companionInterface, primaryMetadata["com.aiarcheology.native.target.interface.json"])
		XCTAssertEqual(companionInterface.contains("proposal_features"), true)
		XCTAssertEqual(companionMetadata["com.aiarcheology.native.target.model-format"], "neuralNetwork")

		// Its weights digest is of its own blob, and it advertises no companions of its own — only the
		// discovery anchor carries the manifest.
		XCTAssertNotEqual(
			companionMetadata["com.aiarcheology.native.conversion.weights-sha256"],
			primaryMetadata["com.aiarcheology.native.conversion.weights-sha256"]
		)
		XCTAssertNil(companionMetadata[NativeModelArtifactManifest.userDefinedKey])
	}

	func testEmitWithROIBoxHeadChunk_whenTheCompanionCannotBeWritten_noPrimaryClaimsIt() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		// A directory sitting on the companion's path makes its write fail. Reversing the write order
		// would leave a primary here advertising a companion that does not exist.
		let companionURL = directory.appendingPathComponent("converted.roi-box-head-chunk.mlmodel")
		try FileManager.default.createDirectory(at: companionURL, withIntermediateDirectories: true)

		XCTAssertThrowsError(try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL, roiBoxHeadChunk: chunk()
		))
		XCTAssertEqual(FileManager.default.fileExists(atPath: modelURL.path), false)
	}

	func testCompanionFilename_derivedFromThePrimary_mustBeAPlainBasename() throws {
		XCTAssertEqual(
			try NativeModelCoreMLEmitter.companionFilename(
				for: .roiBoxHeadChunk, besidePrimaryAt: URL(fileURLWithPath: "/models/converted.mlmodel")
			),
			"converted.roi-box-head-chunk.mlmodel"
		)

		// A percent-encoded separator survives into `lastPathComponent`, so the derived name would be a
		// path the runtime resolves outside the primary's directory.
		let encodedSeparator = try XCTUnwrap(URL(string: "file:///models/..%2Fescaped.mlmodel"))
		assertInvalidArtifactSet(try NativeModelCoreMLEmitter.companionFilename(
			for: .roiBoxHeadChunk, besidePrimaryAt: encodedSeparator
		))
		// A primary with no name of its own would yield a dot-prefixed, traversal-shaped basename.
		assertInvalidArtifactSet(try NativeModelCoreMLEmitter.companionFilename(
			for: .roiBoxHeadChunk, besidePrimaryAt: URL(fileURLWithPath: "/models/.mlmodel")
		))
		assertInvalidArtifactSet(try NativeModelCoreMLEmitter.companionFilename(
			for: .primary, besidePrimaryAt: URL(fileURLWithPath: "/models/converted.mlmodel")
		))
	}

	func testEmitWithROIBoxHeadChunk_rejectsABatchOrProposalCountThatCannotDescribeALoop() throws {
		let modelURL = try temporaryDirectory().appendingPathComponent("converted.mlmodel")
		assertInvalidArtifactSet(try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL,
			roiBoxHeadChunk: chunk(fixedBatchSize: 0)
		))
		assertInvalidArtifactSet(try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL,
			roiBoxHeadChunk: chunk(proposalCount: 0)
		))
		XCTAssertEqual(FileManager.default.fileExists(atPath: modelURL.path), false)
	}

	func testEmitWithROIBoxHeadChunk_stampsOneParityClaimOnBothFiles() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		let artifacts = try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL,
			roiBoxHeadChunk: chunk(), parityEvidence: .verified
		)

		// The primary is useless without the chunk it drives, so the claim covers the pair. A companion
		// left unstamped would be indistinguishable from one nobody ever checked.
		let companionURL = try XCTUnwrap(artifacts.companions.first).url
		for url in [modelURL, companionURL] {
			let json = try XCTUnwrap(userDefined(of: try compiled(at: url))[NativeModelParityProvenance.userDefinedKey])
			XCTAssertEqual(
				try JSONDecoder().decode(NativeModelParityProvenance.self, from: Data(json.utf8)).evidence,
				.verified,
				"\(url.lastPathComponent) must carry the emission's parity claim"
			)
		}
	}

	func testEmit_withoutAChunk_stillWritesExactlyOneUnannotatedModel() throws {
		let directory = try temporaryDirectory()
		let modelURL = directory.appendingPathComponent("converted.mlmodel")
		try NativeModelCoreMLEmitter().emit(graph: primaryGraph(), weights: Data(), to: modelURL)

		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["converted.mlmodel"])
		XCTAssertNil(userDefined(of: try compiled(at: modelURL))[NativeModelArtifactManifest.userDefinedKey])
		let output = try predict(
			try compiled(at: modelURL), feature: "input", shape: [1, 3, 2, 2],
			values: [Float](repeating: 3, count: 12)
		)
		XCTAssertEqual(output.allSatisfy { $0 == 3 }, true)
	}

	/// Emits with the given loop parameters and returns the invocation count the primary's manifest
	/// records — the number a runtime would actually obey.
	private func recordedInvocationCount(fixedBatchSize: Int, proposalCount: Int) throws -> Int {
		let modelURL = try temporaryDirectory().appendingPathComponent("converted.mlmodel")
		try NativeModelCoreMLEmitter().emit(
			graph: primaryGraph(), weights: Data(), to: modelURL,
			roiBoxHeadChunk: chunk(fixedBatchSize: fixedBatchSize, proposalCount: proposalCount)
		)
		let json = try XCTUnwrap(userDefined(of: try compiled(at: modelURL))[NativeModelArtifactManifest.userDefinedKey])
		let manifest = try JSONDecoder().decode(NativeModelArtifactManifest.self, from: Data(json.utf8))
		return try XCTUnwrap(manifest.companions.first).invocationCount
	}

	private func assertInvalidArtifactSet<T>(
		_ expression: @autoclosure () throws -> T,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertThrowsError(try expression(), file: file, line: line) { error in
			guard case .invalidArtifactSet = error as? NativeModelCoreMLEmissionError else {
				return XCTFail("expected an invalidArtifactSet failure, got \(error)", file: file, line: line)
			}
		}
	}

	private func primaryGraph() -> NativeModelGraph {
		reluGraph(input: "input", output: "output", shape: [1, 3, 2, 2])
	}

	/// A stand-in ROI box head: one fixed batch of proposals in, compact per-proposal boxes out,
	/// through a weight-bearing 1x1 projection (an identity kernel plus a per-column bias, so the
	/// prediction is checkable by hand).
	private func chunk(fixedBatchSize: Int = 52, proposalCount: Int = 1000) -> NativeModelROIBoxHeadChunkEmission {
		let shape = [max(fixedBatchSize, 1), 4, 1, 1]
		let identity = (0 ..< 4).flatMap { row in (0 ..< 4).map { Float($0 == row ? 1 : 0) } }
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "proposal_features", dataType: .float32, shape: shape)],
			weights: [
				NativeModelWeight(name: "projection", dataType: .float32, shape: [4, 4, 1, 1], offset: 0, byteCount: 64),
				NativeModelWeight(name: "offsets", dataType: .float32, shape: [4], offset: 64, byteCount: 16)
			],
			operations: [
				NativeModelOperation(
					name: "box_projection",
					kind: .convolution2D,
					inputs: ["proposal_features", "projection", "offsets"],
					outputs: [NativeModelTensor(name: "boxes", dataType: .float32, shape: shape)],
					attributes: [
						"kernelSize": .integers([1, 1]),
						"strides": .integers([1, 1]),
						"padding": .integers([0, 0]),
						"dilations": .integers([1, 1]),
						"groups": .integer(1)
					]
				)
			],
			outputs: ["boxes"]
		)
		return NativeModelROIBoxHeadChunkEmission(
			graph: graph,
			weights: (identity + [1, 2, 3, 4]).withUnsafeBytes { Data($0) },
			fixedBatchSize: fixedBatchSize,
			proposalCount: proposalCount
		)
	}

	private func reluGraph(input: String, output: String, shape: [Int]) -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: input, dataType: .float32, shape: shape)],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "activation",
					kind: .relu,
					inputs: [input],
					outputs: [NativeModelTensor(name: output, dataType: .float32, shape: shape)],
					attributes: [:]
				)
			],
			outputs: [output]
		)
	}

	private func compiled(at url: URL) throws -> MLModel {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return try MLModel(contentsOf: try MLModel.compileModel(at: url), configuration: configuration)
	}

	private func userDefined(of model: MLModel) -> [String: String] {
		model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
	}

	private func predict(_ model: MLModel, feature: String, shape: [Int], values: [Float]) throws -> [Float] {
		let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
		for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
		let provider = try MLDictionaryFeatureProvider(dictionary: [feature: MLFeatureValue(multiArray: array)])
		let prediction = try model.prediction(from: provider)
		let outputName = try XCTUnwrap(model.modelDescription.outputDescriptionsByName.keys.first)
		let output = try XCTUnwrap(prediction.featureValue(for: outputName)?.multiArrayValue)
		return (0 ..< output.count).map { output[$0].floatValue }
	}

	private func fileByteCount(at url: URL) throws -> UInt64 {
		try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value)
	}

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
