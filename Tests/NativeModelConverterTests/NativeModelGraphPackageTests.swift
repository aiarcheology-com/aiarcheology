//
//  NativeModelGraphPackageTests.swift
//  NativeModelConverterTests
//

import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelGraphPackageTests: XCTestCase {

	func testRead_verifiedPackage_returnsGraphAndWeights() async throws {
		let graph = makeReLUGraph()
		let packageURL = try makePackage(graph: graph, weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }

		let package = try await NativeModelGraphPackageReader().read(from: packageURL)

		XCTAssertEqual(package.manifest.format, NativeModelGraphPackageManifest.formatIdentifier)
		XCTAssertEqual(package.graph, graph)
		XCTAssertEqual(package.weights, Data())
	}

	func testRead_modifiedWeights_reportsChecksumMismatch() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data([1, 2, 3]))
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data([1, 2, 4]).write(to: packageURL.appendingPathComponent("weights.bin"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .weightsChecksumMismatch = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected a weights checksum mismatch, got \(error).")
			}
		}
	}

	func testRead_modifiedGraph_reportsChecksumMismatch() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data("{}".utf8).write(to: packageURL.appendingPathComponent("graph.json"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .graphChecksumMismatch = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected a graph checksum mismatch, got \(error).")
			}
		}
	}

	func testRead_modifiedMetadata_reportsChecksumMismatch() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data(), metadata: metadataData())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data("{}".utf8).write(to: packageURL.appendingPathComponent("metadata.json"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .metadataChecksumMismatch = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected a metadata checksum mismatch, got \(error).")
			}
		}
	}

	func testRead_weightRangeOverflow_isRejectedWithoutTrapping() async throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1])],
			weights: [NativeModelWeight(name: "w", dataType: .float32, shape: [1], offset: .max - 3, byteCount: 4)],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
		let packageURL = try makePackage(graph: graph, weights: Data(count: 4))
		defer { try? FileManager.default.removeItem(at: packageURL) }

		// A malformed weight range must fail validation cleanly rather than trap while the reader
		// computes the required weights byte count.
		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .invalidGraph = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected an invalid-graph failure, got \(error).")
			}
		}
	}

	func testRead_legacyManifestWithoutGraphChecksum_isAcceptedAndComputesIt() async throws {
		let graph = makeReLUGraph()
		let packageURL = try makePackage(graph: graph, weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let graphData = try Data(contentsOf: packageURL.appendingPathComponent("graph.json"))
		// An earlier exporter pinned only the weights: no graphSHA256, no metadata.
		let legacyManifest = """
		{"format":"com.aiarcheology.native-model-graph","formatVersion":1,"graph":"graph.json",\
		"weights":"weights.bin","weightsSHA256":"\(checksum(of: Data()))"}
		"""
		try Data(legacyManifest.utf8).write(to: packageURL.appendingPathComponent("manifest.json"))

		let package = try await NativeModelGraphPackageReader().read(from: packageURL)

		XCTAssertEqual(package.graph, graph)
		// The reader fills in the computed graph checksum so provenance stays complete.
		XCTAssertEqual(package.manifest.graphSHA256, checksum(of: graphData))
	}

	func testRead_manifestMissingWeightsChecksum_namesTheMissingField() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let incompleteManifest = """
		{"format":"com.aiarcheology.native-model-graph","formatVersion":1,"graph":"graph.json","weights":"weights.bin"}
		"""
		try Data(incompleteManifest.utf8).write(to: packageURL.appendingPathComponent("manifest.json"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .invalidManifest(let reason) = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected an invalid-manifest failure, got \(error).")
			}
			XCTAssertTrue(reason.contains("weightsSHA256"), "The error should name the missing field: \(reason)")
		}
	}

	func testRead_manifestFormatVersionDiffersFromGraph_isRejected() async throws {
		let graph = makeReLUGraph()
		let packageURL = try makePackage(graph: graph, weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let graphData = try Data(contentsOf: packageURL.appendingPathComponent("graph.json"))
		// Both versions are individually supported and every checksum is correct; only the pairing of
		// the manifest's declared version with the graph it ships is inconsistent.
		let mismatchedManifest = """
		{"format":"com.aiarcheology.native-model-graph","formatVersion":\(NativeModelGraph.exactNDFormatVersion),\
		"graph":"graph.json","weights":"weights.bin","graphSHA256":"\(checksum(of: graphData))",\
		"weightsSHA256":"\(checksum(of: Data()))"}
		"""
		try Data(mismatchedManifest.utf8).write(to: packageURL.appendingPathComponent("manifest.json"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			guard case .invalidManifest(let reason) = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected an invalid-manifest failure, got \(error).")
			}
			XCTAssertTrue(reason.contains("does not match graph formatVersion"), reason)
		}
	}

	func testRead_symbolicLinkPackageRoot_isRejected() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let linkURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("\(UUID().uuidString).aiagraph", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: packageURL)
		defer { try? FileManager.default.removeItem(at: linkURL) }

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: linkURL)) { error in
			guard case .symbolicLinkNotAllowed = error as? NativeModelGraphPackageError else {
				return XCTFail("Expected a symbolic-link rejection, got \(error).")
			}
		}
	}

	func testRead_unexpectedPackageFile_reportsLayoutFailure() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data("not part of the format".utf8).write(to: packageURL.appendingPathComponent("unexpected.bin"))

		await XCTAssertThrowsErrorAsync(try await NativeModelGraphPackageReader().read(from: packageURL)) { error in
			XCTAssertEqual(error as? NativeModelGraphPackageError, .unexpectedFile("unexpected.bin"))
		}
	}

	func testEmit_verifiedPackage_compilesWithCoreML() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let package = try await NativeModelGraphPackageReader().read(from: packageURL)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")

		try NativeModelCoreMLEmitter().emit(package: package, to: modelURL)

		do {
			_ = try await MLModel.compileModel(at: modelURL)
		} catch {
			XCTFail("Expected package-emitted model to compile: \(error)")
		}
	}

	func testEmit_metadata_preservesSourceClassesWithoutClaimingTargetClassifierLabels() async throws {
		let metadata = metadataData()
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data(), metadata: metadata)
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let package = try await NativeModelGraphPackageReader().read(from: packageURL)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let sidecarURL = NativeModelMetadataSidecar.url(for: modelURL)
		defer {
			try? FileManager.default.removeItem(at: modelURL)
			try? FileManager.default.removeItem(at: sidecarURL)
		}

		try NativeModelCoreMLEmitter().emit(package: package, to: modelURL)
		XCTAssertEqual(try Data(contentsOf: sidecarURL), metadata)
		let sourceMetadata = try XCTUnwrap(
			try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
		)
		XCTAssertEqual(sourceMetadata["labels"] as? [String], ["mound", "ditch"])

		let compiledURL = try await MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL)
		let modelMetadata = model.modelDescription.metadata
		XCTAssertEqual(
			modelMetadata[.description] as? String,
			"Converted Core ML neural-network model. Source description: Original classifier"
		)
		XCTAssertEqual(modelMetadata[.versionString] as? String, "source-1.2.3")
		XCTAssertEqual(modelMetadata[.author] as? String, "Original author")
		XCTAssertEqual(modelMetadata[.license] as? String, "Apache-2.0")
		let userDefined = try XCTUnwrap(modelMetadata[.creatorDefinedKey] as? [String: String])
		XCTAssertEqual(userDefined["com.aiarcheology.native.source.user-defined.task"], "classify")
		XCTAssertEqual(userDefined["com.aiarcheology.native.source.user-defined.names"], "[\"mound\",\"ditch\"]")
		XCTAssertNil(
			userDefined["names"],
			"Source labels must not be presented as target classifier labels before a classifier wrapper is emitted."
		)
		XCTAssertEqual(userDefined["com.aiarcheology.native.target.model-format"], "neuralNetwork")
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.converter.package-version"],
			NativeModelConverterVersion.packageVersion
		)
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.converter.conversion-revision"],
			String(NativeModelConverterVersion.conversionRevision)
		)
		// A package conversion runs no numeric check, so it must claim no more than a structural match.
		XCTAssertEqual(
			userDefined[NativeModelParityProvenance.userDefinedKey],
			try NativeModelParityProvenance(evidence: .structurallyMatched).canonicalJSON()
		)
		XCTAssertEqual(userDefined["com.aiarcheology.native.conversion.producer.name"], "tests")
		XCTAssertEqual(userDefined["com.aiarcheology.native.conversion.producer.version"], "1.0.0")
		XCTAssertEqual(userDefined["com.aiarcheology.native.conversion.source-metadata-sha256"], checksum(of: metadata))
		XCTAssertNil(userDefined["task"], "Source task must not be presented as an unverified target claim.")
	}

	func testEmit_packageWithLabels_emitsCoreMLClassifier() async throws {
		// input [1,3] --linear(identity)--> logits [1,3]; labels match the 3-wide output.
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 3])],
			weights: [
				NativeModelWeight(name: "w", dataType: .float32, shape: [3, 3], offset: 0, byteCount: 36),
				NativeModelWeight(name: "b", dataType: .float32, shape: [3], offset: 36, byteCount: 12)
			],
			operations: [
				NativeModelOperation(
					name: "classifier",
					kind: .linear,
					inputs: ["input", "w", "b"],
					outputs: [NativeModelTensor(name: "logits", dataType: .float32, shape: [1, 3])],
					attributes: [:]
				)
			],
			outputs: ["logits"]
		)
		let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
		let weights = identity.withUnsafeBytes { Data($0) }
		let metadata = Data("""
		{"format":"com.aiarcheology.native-model-metadata","formatVersion":1,\
		"source":{"shortDescription":"tiny classifier"},"labels":["cat","dog","bird"]}
		""".utf8)
		let packageURL = try makePackage(graph: graph, weights: weights, metadata: metadata)
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let package = try await NativeModelGraphPackageReader().read(from: packageURL)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer {
			try? FileManager.default.removeItem(at: modelURL)
			try? FileManager.default.removeItem(at: NativeModelMetadataSidecar.url(for: modelURL))
		}

		try NativeModelCoreMLEmitter().emit(package: package, to: modelURL)

		let compiledURL = try await MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL)
		let userDefined = try XCTUnwrap(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
		let targetSemantics = try XCTUnwrap(NativeModelTargetSemantics(userDefined: userDefined))
		XCTAssertEqual(targetSemantics.task, .classification)
		XCTAssertEqual(targetSemantics.labelProfile, .sourceMetadata)
		XCTAssertEqual(targetSemantics.preprocessingProfile, .none)
		XCTAssertFalse(targetSemantics.requiresImportAssumptionNotice)
		// The model description must expose the classifier interface, not a raw multi-array.
		XCTAssertEqual(model.modelDescription.predictedFeatureName, "classLabel")
		XCTAssertEqual(model.modelDescription.outputDescriptionsByName["classLabel"]?.type, .string)
		XCTAssertEqual(model.modelDescription.outputDescriptionsByName["classLabelProbs"]?.type, .dictionary)

		let input = try MLMultiArray(shape: [1, 3], dataType: .float32)
		input[0] = 0.1
		input[1] = 5.0 // argmax → index 1 → "dog"
		input[2] = 0.2
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
		let prediction = try await model.prediction(from: provider)

		XCTAssertEqual(prediction.featureValue(for: "classLabel")?.stringValue, "dog")
		let probs = try XCTUnwrap(prediction.featureValue(for: "classLabelProbs")?.dictionaryValue as? [String: Double])
		XCTAssertEqual(Set(probs.keys), ["cat", "dog", "bird"])
		XCTAssertEqual(probs.values.reduce(0, +), 1.0, accuracy: 0.001, "Softmax probabilities must sum to 1.")
		XCTAssertEqual(probs.max(by: { $0.value < $1.value })?.key, "dog")
	}

	func testEmit_packageWithoutMetadata_removesStaleSidecar() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let package = try await NativeModelGraphPackageReader().read(from: packageURL)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let sidecarURL = NativeModelMetadataSidecar.url(for: modelURL)
		defer {
			try? FileManager.default.removeItem(at: modelURL)
			try? FileManager.default.removeItem(at: sidecarURL)
		}
		try Data("stale".utf8).write(to: sidecarURL)

		try NativeModelCoreMLEmitter().emit(package: package, to: modelURL)

		XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
	}

	func testConvert_reportsExactArtifactSizesAndSerializableTiming() async throws {
		let metadata = metadataData()
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data(), metadata: metadata)
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let sidecarURL = NativeModelMetadataSidecar.url(for: modelURL)
		defer {
			try? FileManager.default.removeItem(at: modelURL)
			try? FileManager.default.removeItem(at: sidecarURL)
		}

		let progress = ProgressCollector()
		let metrics = try await NativeModelConverter().convert(
			from: packageURL,
			to: modelURL,
			sourceProvenance: NativeModelConversionSourceProvenance(
				originalModelFilename: "upstream-mobilenetv2.onnx",
				originalModelURL: "https://models.example.invalid/mobilenetv2.onnx"
			)
		) { update in
			progress.append(update)
		}

		XCTAssertEqual(
			metrics.sourceFootprint.manifestByteCount,
			UInt64(try Data(contentsOf: packageURL.appendingPathComponent("manifest.json")).count)
		)
		XCTAssertEqual(
			metrics.sourceFootprint.graphByteCount,
			UInt64(try Data(contentsOf: packageURL.appendingPathComponent("graph.json")).count)
		)
		XCTAssertEqual(metrics.sourceFootprint.weightsByteCount, 0)
		XCTAssertEqual(metrics.sourceFootprint.metadataByteCount, UInt64(metadata.count))
		XCTAssertEqual(metrics.emission.operationCount, 1)
		XCTAssertEqual(metrics.emission.outputModelByteCount, UInt64(try Data(contentsOf: modelURL).count))
		XCTAssertEqual(metrics.emission.outputMetadataSidecarByteCount, UInt64(metadata.count))
		XCTAssertEqual(
			metrics.totalConversionDurationNanoseconds,
			metrics.packageReadDurationNanoseconds + metrics.emission.emissionDurationNanoseconds
		)
		let processMemoryUsage = try XCTUnwrap(metrics.processMemoryUsage)
		XCTAssertGreaterThan(processMemoryUsage.baselineProcessFootprintByteCount, 0)
		XCTAssertGreaterThan(processMemoryUsage.currentProcessFootprintByteCount, 0)
		XCTAssertGreaterThanOrEqual(
			processMemoryUsage.peakObservedProcessFootprintByteCount,
			processMemoryUsage.baselineProcessFootprintByteCount
		)

		let decoded = try JSONDecoder().decode(
			NativeModelConversionMetrics.self,
			from: JSONEncoder().encode(metrics)
		)
		XCTAssertEqual(decoded, metrics)

		let updates = progress.values
		XCTAssertEqual(updates.first?.phase, .waitingForExclusiveAccess)
		XCTAssertNil(updates.first?.processMemoryUsage, "A queued job does not own conversion memory yet.")
		XCTAssertEqual(updates.last?.phase, .completed)
		XCTAssertTrue(
			updates.dropFirst().allSatisfy { $0.processMemoryUsage != nil },
			"Every progress boundary after exclusive access should include a whole-process memory sample."
		)
		XCTAssertTrue(updates.contains { $0.phase == .validatingGraph })
		XCTAssertTrue(updates.contains { $0.phase == .writingModel && $0.completedUnitCount == 1 })
		XCTAssertEqual(
			updates.filter { $0.phase == .emittingModel }.map(\.completedUnitCount),
			[0, 1]
		)

		let compiledURL = try await MLModel.compileModel(at: modelURL)
		let compiledModel = try MLModel(contentsOf: compiledURL)
		let userDefined = try XCTUnwrap(compiledModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.conversion.source-package-filename"],
			packageURL.lastPathComponent
		)
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.conversion.original-model-filename"],
			"upstream-mobilenetv2.onnx"
		)
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.conversion.original-model-url"],
			"https://models.example.invalid/mobilenetv2.onnx"
		)
	}

	func testConvert_withoutProgressHandler_stillRecordsProcessMemory() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }

		let metrics = try await NativeModelConverter().convert(from: packageURL, to: modelURL)

		let processMemoryUsage = try XCTUnwrap(metrics.processMemoryUsage)
		XCTAssertGreaterThan(processMemoryUsage.baselineProcessFootprintByteCount, 0)
		XCTAssertGreaterThanOrEqual(
			processMemoryUsage.peakObservedProcessFootprintByteCount,
			processMemoryUsage.baselineProcessFootprintByteCount
		)
	}

	func testConvert_wrapsPackageFailureInStableDiagnosticAndReportsFailedProgress() async throws {
		let packageURL = try makePackage(graph: makeReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		try Data("{}".utf8).write(to: packageURL.appendingPathComponent("graph.json"))
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }
		let progress = ProgressCollector()

		do {
			_ = try await NativeModelConverter().convert(from: packageURL, to: modelURL) { update in
				progress.append(update)
			}
			XCTFail("Expected conversion to fail for a changed graph.")
		} catch let error as NativeModelConversionError {
			XCTAssertEqual(error.diagnostic.code, "package.graphChecksumMismatch")
			XCTAssertEqual(error.diagnostic.phase, .validatingGraph)
			XCTAssertTrue(error.localizedDescription.contains("native-model-conversion.package.graphChecksumMismatch"))
		} catch {
			XCTFail("Expected NativeModelConversionError, got \(error).")
		}

		XCTAssertEqual(progress.values.last?.phase, .failed)
	}

	func testConvert_cancellationReportsStableDiagnosticAndLeavesNoCommittedModel() async throws {
		let packageURL = try makePackage(graph: makeTwoReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }
		let reachedEmission = DispatchSemaphore(value: 0)
		let allowNextOperation = DispatchSemaphore(value: 0)
		let progress = ProgressCollector()

		let task = Task {
			try await NativeModelConverter().convert(from: packageURL, to: modelURL) { update in
				progress.append(update)
				if update.phase == .emittingModel, update.completedUnitCount == 0 {
					reachedEmission.signal()
					allowNextOperation.wait()
				}
			}
		}
		XCTAssertEqual(reachedEmission.wait(timeout: .now() + 5), .success)
		task.cancel()
		allowNextOperation.signal()

		do {
			_ = try await task.value
			XCTFail("Expected the conversion to be cancelled.")
		} catch let error as NativeModelConversionError {
			XCTAssertEqual(error.diagnostic.code, "cancelled")
			XCTAssertEqual(error.diagnostic.phase, .emittingModel)
		} catch {
			XCTFail("Expected NativeModelConversionError, got \(error).")
		}

		XCTAssertEqual(progress.values.last?.phase, .cancelled)
		XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
	}

	/// Waits until the process-wide gate actually holds `count` queued jobs.
	///
	/// Bounded so a broken seam fails fast with something readable rather than spinning to the
	/// xcodebuild timeout. `Task.yield()` rather than a sleep: the jobs being waited on are hopping
	/// to an actor, and yielding gives the cooperative pool the chance to run them.
	private func awaitQueuedJobCount(
		_ count: Int,
		timeout: TimeInterval = 5,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let deadline = Date().addingTimeInterval(timeout)
		while await NativeModelConverter.queuedJobCountForTesting() != count {
			if Date() > deadline {
				let actual = await NativeModelConverter.queuedJobCountForTesting()
				XCTFail("expected \(count) queued job(s), found \(actual)", file: file, line: line)
				return
			}
			await Task.yield()
		}
	}

	func testConvert_serializesProcessWideJobsInFIFOOrder() async throws {
		let packageURL = try makePackage(graph: makeTwoReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let firstModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let secondModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let thirdModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer {
			try? FileManager.default.removeItem(at: firstModelURL)
			try? FileManager.default.removeItem(at: secondModelURL)
			try? FileManager.default.removeItem(at: thirdModelURL)
		}
		let firstReachedEmission = DispatchSemaphore(value: 0)
		let allowFirstConversion = DispatchSemaphore(value: 0)
		let secondQueued = DispatchSemaphore(value: 0)
		let secondReachedEmission = DispatchSemaphore(value: 0)
		let allowSecondConversion = DispatchSemaphore(value: 0)
		let thirdQueued = DispatchSemaphore(value: 0)
		let secondProgress = ProgressCollector()
		let thirdProgress = ProgressCollector()

		let first = Task {
			try await NativeModelConverter().convert(from: packageURL, to: firstModelURL) { update in
				if update.phase == .emittingModel, update.completedUnitCount == 0 {
					firstReachedEmission.signal()
					allowFirstConversion.wait()
				}
			}
		}
		XCTAssertEqual(firstReachedEmission.wait(timeout: .now() + 5), .success)

		let second = Task {
			try await NativeModelConverter().convert(from: packageURL, to: secondModelURL) { update in
				secondProgress.append(update)
				if update.phase == .waitingForExclusiveAccess {
					secondQueued.signal()
				}
				if update.phase == .emittingModel, update.completedUnitCount == 0 {
					secondReachedEmission.signal()
					allowSecondConversion.wait()
				}
			}
		}
		XCTAssertEqual(secondQueued.wait(timeout: .now() + 5), .success)
		// `secondQueued` fires from the progress callback, which runs *before* the job awaits the
		// gate — so it proves the job started, not that it holds a queue slot. Launching the third
		// job on that signal alone races the actor hop between the two, and Swift orders contending
		// hops from different tasks arbitrarily: the third could enqueue first, run first on
		// release, and fail the ordering assertions below in milliseconds. Wait for the queue itself.
		await awaitQueuedJobCount(1)

		let third = Task {
			try await NativeModelConverter().convert(from: packageURL, to: thirdModelURL) { update in
				thirdProgress.append(update)
				if update.phase == .waitingForExclusiveAccess {
					thirdQueued.signal()
				}
			}
		}
		XCTAssertEqual(thirdQueued.wait(timeout: .now() + 5), .success)
		// Same reason: both must be *in* the queue before its order can be asserted.
		await awaitQueuedJobCount(2)
		XCTAssertEqual(secondProgress.values.map(\.phase), [.waitingForExclusiveAccess])
		XCTAssertEqual(thirdProgress.values.map(\.phase), [.waitingForExclusiveAccess])

		allowFirstConversion.signal()
		XCTAssertEqual(secondReachedEmission.wait(timeout: .now() + 5), .success)
		XCTAssertEqual(
			thirdProgress.values.map(\.phase),
			[.waitingForExclusiveAccess],
			"The third job must remain queued while the second FIFO job owns the gate."
		)

		allowSecondConversion.signal()
		_ = try await first.value
		_ = try await second.value
		_ = try await third.value
		XCTAssertEqual(secondProgress.values.first?.phase, .waitingForExclusiveAccess)
		XCTAssertEqual(thirdProgress.values.first?.phase, .waitingForExclusiveAccess)
		XCTAssertTrue(secondProgress.values.contains { $0.phase == .completed })
		XCTAssertTrue(thirdProgress.values.contains { $0.phase == .completed })
	}

	func testConvert_cancellingQueuedJobReportsWaitingPhaseAndReleasesItsQueueSlot() async throws {
		let packageURL = try makePackage(graph: makeTwoReLUGraph(), weights: Data())
		defer { try? FileManager.default.removeItem(at: packageURL) }
		let firstModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let secondModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		let thirdModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer {
			try? FileManager.default.removeItem(at: firstModelURL)
			try? FileManager.default.removeItem(at: secondModelURL)
			try? FileManager.default.removeItem(at: thirdModelURL)
		}
		let firstReachedEmission = DispatchSemaphore(value: 0)
		let allowFirstConversion = DispatchSemaphore(value: 0)
		let secondQueued = DispatchSemaphore(value: 0)
		let secondProgress = ProgressCollector()

		let first = Task {
			try await NativeModelConverter().convert(from: packageURL, to: firstModelURL) { update in
				if update.phase == .emittingModel, update.completedUnitCount == 0 {
					firstReachedEmission.signal()
					allowFirstConversion.wait()
				}
			}
		}
		XCTAssertEqual(firstReachedEmission.wait(timeout: .now() + 5), .success)

		let second = Task {
			try await NativeModelConverter().convert(from: packageURL, to: secondModelURL) { update in
				secondProgress.append(update)
				if update.phase == .waitingForExclusiveAccess {
					secondQueued.signal()
				}
			}
		}
		XCTAssertEqual(secondQueued.wait(timeout: .now() + 5), .success)
		second.cancel()

		do {
			_ = try await second.value
			XCTFail("Expected a queued conversion to be cancelled.")
		} catch let error as NativeModelConversionError {
			XCTAssertEqual(error.diagnostic.code, "cancelled")
			XCTAssertEqual(error.diagnostic.phase, .waitingForExclusiveAccess)
		} catch {
			XCTFail("Expected NativeModelConversionError, got \(error).")
		}
		XCTAssertEqual(secondProgress.values.map(\.phase), [.waitingForExclusiveAccess, .cancelled])

		allowFirstConversion.signal()
		_ = try await first.value
		_ = try await NativeModelConverter().convert(from: packageURL, to: thirdModelURL)
		XCTAssertTrue(FileManager.default.fileExists(atPath: thirdModelURL.path))
	}

	private func makeReLUGraph() -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
	}

	private func makeTwoReLUGraph() -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "relu-1",
					kind: .relu,
					inputs: ["input"],
					outputs: [NativeModelTensor(name: "middle", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "relu-2",
					kind: .relu,
					inputs: ["middle"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
	}

	private func makePackage(graph: NativeModelGraph, weights: Data, metadata: Data? = nil) throws -> URL {
		let packageURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
			.appendingPathExtension("aiagraph")
		try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
		let graphData = try JSONEncoder().encode(graph)
		let manifest = NativeModelGraphPackageManifest(
			formatVersion: graph.formatVersion,
			graphSHA256: checksum(of: graphData),
			weightsSHA256: checksum(of: weights),
			metadataSHA256: metadata.map(checksum(of:))
		)
		try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent("manifest.json"))
		try graphData.write(to: packageURL.appendingPathComponent("graph.json"))
		try weights.write(to: packageURL.appendingPathComponent("weights.bin"))
		if let metadata {
			try metadata.write(to: packageURL.appendingPathComponent("metadata.json"))
		}
		return packageURL
	}

	private func metadataData() -> Data {
		Data("""
		{
		  "format":"com.aiarcheology.native-model-metadata",
		  "formatVersion":1,
		  "source":{
		    "shortDescription":"Original classifier",
		    "versionString":"source-1.2.3",
		    "author":"Original author",
		    "license":"Apache-2.0",
		    "userDefined":{"task":"classify","names":"[\\"mound\\",\\"ditch\\"]"}
		  },
		  "labels":["mound","ditch"],
		  "preprocessing":{"normalization":{"mean":[0.1,0.2,0.3]}},
		  "provenance":{"repository":"https://example.invalid/model"}
		}
		""".utf8)
	}

	private func checksum(of data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

private func XCTAssertThrowsErrorAsync<T>(
	_ expression: @autoclosure () async throws -> T,
	_ errorHandler: (Error) -> Void
) async {
	do {
		_ = try await expression()
		XCTFail("Expected an error to be thrown.")
	} catch {
		errorHandler(error)
	}
}

private final class ProgressCollector: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [NativeModelConversionProgress] = []

	func append(_ update: NativeModelConversionProgress) {
		lock.lock()
		defer { lock.unlock() }
		storage.append(update)
	}

	var values: [NativeModelConversionProgress] {
		lock.lock()
		defer { lock.unlock() }
		return storage
	}
}
