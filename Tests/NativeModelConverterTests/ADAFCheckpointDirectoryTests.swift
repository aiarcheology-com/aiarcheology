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
