//
//  ADAFCheckpointDirectoryTests.swift
//  NativeModelConverterTests
//
//  The gated suite: every published ADAF checkpoint, fetched rather than committed (AIA-0666).
//

import XCTest
@testable import NativeModelConverter

/// Runs the reader against files this repository does not contain.
///
/// The always-on suite covers the reader's whole read set from committed byte ranges, so this is the
/// redundant check rather than the only one — but it is redundant in the useful direction: it opens
/// files fetched fresh from Zenodo, including the three published detection models whose bytes are
/// not committed here, and (with `--full`) files whose middle is real weight data instead of a hole.
///
/// Gated on `ADAF_CHECKPOINT_DIRECTORY`. A gate that skips silently is the hazard `ios/AGENTS.md`
/// §13 records for the other two fixture gates, so `scripts/test_adaf_checkpoints.sh` is the way to
/// run this: it fails when the fixtures are absent or when any test skipped, which `swift test`
/// alone will not.
final class ADAFCheckpointDirectoryTests: XCTestCase {

	/// Every model in the manifest, opened from the fetched directory and identified.
	func test_everyPublishedCheckpoint_isReadAndIdentified() throws {
		let directory = try requireDirectory()
		let manifest = try ADAFFixtures.manifest()
		XCTAssertFalse(manifest.models.isEmpty)

		for model in manifest.models {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else {
				XCTFail("\(model.fileName) is not in \(directory.path) — run scripts/fetch_adaf_checkpoints.sh")
				continue
			}

			let source = try FileBytes(url: url)
			XCTAssertEqual(source.totalLength, model.totalLength, model.fileName)

			let counting = CountingBytes(source)
			let checkpoint = try PyTorchCheckpointReader.read(counting)

			if let tensorCount = model.tensorCount {
				XCTAssertEqual(checkpoint.tensors.count, tensorCount, model.fileName)
			}
			XCTAssertEqual(checkpoint.formatVersion, 3, model.fileName)

			// The read-set guarantee, asserted here too. Against a whole file every byte is available,
			// so without this the budget would be proven only by the sparse fixture and would vanish
			// with it.
			XCTAssertLessThan(counting.bytesRead, 2 * 1_024 * 1_024,
							  "\(model.fileName): read \(counting.bytesRead) of \(model.totalLength) bytes")

			switch (ADAFCheckpointCatalog.identity(of: checkpoint), model.expects) {
			case (.objectDetection(let detector), "objectDetection"):
				XCTAssertEqual(detector.predictorLogitCount, 2, model.fileName)
				XCTAssertEqual(detector.detectableClassCount, 1, model.fileName)
				XCTAssertEqual(detector.classLabel?.displayName, model.classLabel, model.fileName)
				XCTAssertEqual(detector.labelProvenance, .checkpointIdentifier, model.fileName)
			case (.segmentation, "segmentation"):
				break
			case (let identity, let expected):
				XCTFail("\(model.fileName): expected \(expected ?? "nothing"), got \(identity)")
			}
		}
	}

	/// All four detection checkpoints must share one tensor table — the fact the pinned digest rests
	/// on, and the reason the class label has to come from the training `id`.
	/// Every weight in a whole checkpoint, extracted to fp16 and accounted for (AIA-0675).
	///
	/// This is the only place the extractor meets a real file end to end. The always-on suite reaches
	/// five storages out of 339, because that is all the committed head can hold; a sparse fetched
	/// copy reaches barely more, since its middle is a hole of zeros that would fail the first
	/// checksum it touched. So a **whole** copy is required here and a sparse one is skipped by name
	/// rather than quietly passing on a prefix — `--full` is the only way this test means anything.
	func test_wholeDetectionCheckpoints_extractEveryWeightToFloat16() throws {
		let directory = try requireDirectory()
		let manifest = try ADAFFixtures.manifest()
		var examined = 0
		var sparse: [String] = []

		for model in manifest.models where model.expects == "objectDetection" {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else { continue }
			let marker = directory.appendingPathComponent(".\(model.fileName).sparse")
			if FileManager.default.fileExists(atPath: marker.path) {
				sparse.append(model.fileName)
				continue
			}

			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: url)
			let destination = FileManager.default.temporaryDirectory
				.appendingPathComponent("\(model.id)-weights-\(UUID().uuidString).bin", isDirectory: false)
			let started = Date()
			let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: url, to: destination)
			let elapsed = Date().timeIntervalSince(started)
			defer { try? FileManager.default.removeItem(at: destination) }

			// Nothing may simply disappear between the state_dict and the blob.
			XCTAssertEqual(
				extraction.weights.count + extraction.skippedCounterTensors.count,
				checkpoint.tensors.count, model.fileName
			)
			XCTAssertEqual(extraction.weights.count, 339, model.fileName)
			XCTAssertEqual(extraction.skippedCounterTensors.count, 65, model.fileName)
			XCTAssertTrue(
				extraction.skippedCounterTensors.allSatisfy { $0.hasSuffix(".num_batches_tracked") },
				"\(model.fileName): something other than a BatchNorm counter was skipped"
			)
			XCTAssertEqual(extraction.sourceByteCount, 173_261_668, model.fileName)
			XCTAssertEqual(extraction.byteCount, 86_630_834, model.fileName)
			XCTAssertEqual(
				UInt64(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? -1),
				extraction.byteCount, model.fileName
			)

			// The reason this milestone can store fp16 at all: measured on the real file, the largest
			// weight magnitude in `OD_ringfort` is 5.24, four orders of magnitude under fp16's 65,504
			// ceiling. If a published checkpoint ever did carry one that overflows, extraction refuses
			// it by name rather than writing an infinity — this asserts that has not happened.
			let footprint = extraction.memory?.observedPeakIncreaseByteCount
			print("""
				[AIA-0675] \(model.fileName): \(extraction.weights.count) weights, \
				\(extraction.byteCount) bytes, sha256 \(extraction.sha256), \
				peak increase \(footprint.map(String.init) ?? "unavailable") bytes, \
				\(String(format: "%.1f", elapsed)) s
				""")
			if let footprint {
				// Bounded by the chunk, not by the checkpoint. Generous because this is a *process*
				// figure that includes whatever the test host already held; the claim being defended is
				// that it does not scale with the 165 MiB being read.
				XCTAssertLessThan(footprint, 64 * 1_024 * 1_024, "\(model.fileName): extraction is not streaming")
			}
			examined += 1
		}

		XCTAssertGreaterThan(examined, 0, "no whole detection checkpoint was available — fetch with --full")
		// Without this the test passes on one whole detector beside three sparse ones, while claiming
		// end-to-end coverage for every detector present.
		XCTAssertEqual(
			sparse, [],
			"these detectors are present but sparse, so their weights were never extracted: \(sparse)"
		)
	}

	/// The same attack as the built-archive test, with the files that make it plausible (AIA-0675).
	///
	/// `test_theFourDetectionCheckpoints_shareOneTensorTable` is the reason this matters: the four
	/// published detectors are indistinguishable by tensor table, so extracting one model's weights
	/// against another's description passes every structural check there is. Only the pickle's
	/// checksum differs, because only the `id` string does.
	func test_oneDetectorsDescriptionAgainstAnothersBytes_isRefused() throws {
		let directory = try requireDirectory()
		let first = directory.appendingPathComponent("OD_ringfort.tar")
		let second = directory.appendingPathComponent("OD_barrow.tar")
		guard FileManager.default.fileExists(atPath: first.path),
			FileManager.default.fileExists(atPath: second.path)
		else {
			throw XCTSkip("needs both OD_ringfort and OD_barrow")
		}

		let ringfort = try PyTorchCheckpointReader.read(contentsOf: first)
		let barrow = try PyTorchCheckpointReader.read(contentsOf: second)
		XCTAssertEqual(
			ringfort.tensors, barrow.tensors,
			"if these ever differ, this test is no longer testing the case it was written for"
		)

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent("swap-\(UUID().uuidString).bin", isDirectory: false)
		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(ringfort, from: second, to: destination)) {
			XCTAssertEqual($0 as? PyTorchWeightExtractionError, .checkpointDescribesAnotherArchive)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	func test_theFourDetectionCheckpoints_shareOneTensorTable() throws {
		let directory = try requireDirectory()
		let detection = try ADAFFixtures.manifest().models.filter { $0.expects == "objectDetection" }
		XCTAssertEqual(detection.count, 4, "the record publishes four OD_* models")

		var digests: Set<UInt64> = []
		var labels: Set<String> = []
		for model in detection {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else {
				XCTFail("\(model.fileName) is missing — run scripts/fetch_adaf_checkpoints.sh")
				continue
			}
			let checkpoint = try PyTorchCheckpointReader.read(try FileBytes(url: url))
			digests.insert(ADAFCheckpointCatalog.tableDigest(of: checkpoint.tensors))
			if case .objectDetection(let detector) = ADAFCheckpointCatalog.identity(of: checkpoint),
				let label = detector.classLabel?.displayName {
				labels.insert(label)
			}
		}
		XCTAssertEqual(digests, [ADAFCheckpointCatalog.objectDetectionDigest],
					   "the four detection checkpoints must digest identically")
		XCTAssertEqual(labels, ["All archaeology", "Barrow", "Enclosure", "Ringfort"],
					   "each one must still resolve to its own class")
	}

	private func requireDirectory() throws -> URL {
		try XCTSkipIf(
			ADAFFixtures.gatedDirectory == nil,
			"""
			ADAF_CHECKPOINT_DIRECTORY is not set, so this suite did nothing. That is a coverage hole, \
			not a pass: run scripts/test_adaf_checkpoints.sh, which fails instead of skipping.
			"""
		)
		return try XCTUnwrap(ADAFFixtures.gatedDirectory)
	}
}
