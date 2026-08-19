//
//  ADAFCheckpointCatalogTests.swift
//  NativeModelConverterTests
//
//  AIA-0666.
//

import XCTest
@testable import NativeModelConverter

final class ADAFCheckpointCatalogTests: XCTestCase {

	// MARK: - The real checkpoints

	func test_theRealDetectionCheckpoint_isRecognisedAndLabelled() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		guard case .objectDetection(let model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("not recognised as an ADAF detector")
		}
		XCTAssertEqual(model.architecture, "fasterrcnn_resnet50_fpn_v2")
		XCTAssertEqual(model.predictorLogitCount, 2)
		XCTAssertEqual(model.detectableClassCount, 1, "background plus one class means it finds one thing")
		XCTAssertEqual(model.classLabel, .ringfort)
		XCTAssertEqual(model.classLabel?.displayName, "Ringfort")
		XCTAssertEqual(model.labelProvenance, .checkpointIdentifier)
	}

	/// Segmentation is refused permanently, not "not yet": the app has no representation for a
	/// per-pixel mask anywhere (AIA-0654 scope decision).
	func test_theRealSegmentationCheckpoint_isIdentifiedAsSegmentation() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("AO_HRNet"))
		XCTAssertEqual(ADAFCheckpointCatalog.identity(of: checkpoint), .segmentation(architecture: "HRNet"))
	}

	/// The digest is pinned, so drift in the canonical form shows up here rather than as a model
	/// silently ceasing to be recognised.
	func test_theRealTableDigests_areTheOnesPinned() throws {
		let detection = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		XCTAssertEqual(ADAFCheckpointCatalog.tableDigest(of: detection.tensors),
					   ADAFCheckpointCatalog.objectDetectionDigest)

		let segmentation = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("AO_HRNet"))
		XCTAssertEqual(ADAFCheckpointCatalog.tableDigest(of: segmentation.tensors),
					   ADAFCheckpointCatalog.segmentationDigest)

		XCTAssertNotEqual(ADAFCheckpointCatalog.objectDetectionDigest,
						  ADAFCheckpointCatalog.segmentationDigest)
	}

	// MARK: - Recognition needs the whole table, not a handful of probes

	/// The reason recognition is a digest and not the probe list: every probe passes here, and this is
	/// a seven-tensor fragment.
	func test_aFragmentSatisfyingEveryProbe_isNotRecognised() throws {
		let probes: [(String, [Int])] = [
			("backbone.body.conv1.weight", [64, 3, 7, 7]),
			("backbone.fpn.inner_blocks.0.1.weight", [256]),
			("rpn.head.conv.0.0.weight", [256, 256, 3, 3]),
			("rpn.head.conv.1.0.weight", [256, 256, 3, 3]),
			("rpn.head.cls_logits.weight", [3, 256, 1, 1]),
			("roi_heads.box_head.5.weight", [1024, 12544]),
			("roi_heads.box_predictor.cls_score.weight", [2, 1024])
		]
		let checkpoint = Self.checkpoint(tensors: probes, identifier: "train_ringfort_OD")

		guard case .unrecognized(let summary) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("a seven-tensor fragment must not pass as the pinned model")
		}
		XCTAssertEqual(summary.tensorCount, 7)
		// It still says something useful rather than shrugging.
		XCTAssertEqual(summary.architectureFamily, "Faster R-CNN")
		XCTAssertEqual(summary.topLevelPrefixes, ["backbone", "rpn", "roi_heads"])
	}

	/// One tensor removed from the real table must stop it being recognised.
	func test_theRealTableMinusOneTensor_isNotRecognised() throws {
		let real = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		let truncated = Self.checkpoint(tensors: real.tensors.dropLast().map { ($0.name, $0.shape) },
										identifier: real.identifier)
		guard case .unrecognized = ADAFCheckpointCatalog.identity(of: truncated) else {
			return XCTFail("403 of 404 tensors must not match the pinned table")
		}
	}

	/// A shape change with the names untouched must also break recognition — the digest covers shapes
	/// and dtypes, not just names.
	func test_theRealTableWithOneShapeChanged_isNotRecognised() throws {
		let real = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		let altered = Self.checkpoint(
			tensors: real.tensors.map { ($0.name, $0.name == "roi_heads.box_predictor.cls_score.weight" ? [3, 1024] : $0.shape) },
			identifier: real.identifier
		)
		guard case .unrecognized = ADAFCheckpointCatalog.identity(of: altered) else {
			return XCTFail("a changed shape must not match the pinned table")
		}
	}

	// MARK: - Labels

	func test_eachPublishedIdentifier_yieldsItsClass() {
		let cases: [(String, ADAFClass, String)] = [
			("train_ringfort_OD_SLRM_512px pretrained_train_12_val_124", .ringfort, "Ringfort"),
			("train_barrow_OD_SLRM_512px pretrained_train_12_val_124", .barrow, "Barrow"),
			("train_enclosure_OD_SLRM_512px pretrained_train_12_val_124", .enclosure, "Enclosure"),
			("train_AO_OD_SLRM_512px pretrained_train_12_val_124", .allArchaeology, "All archaeology")
		]
		for (identifier, expected, display) in cases {
			let (label, provenance) = ADAFCheckpointCatalog.classLabel(from: identifier)
			XCTAssertEqual(label, expected, identifier)
			XCTAssertEqual(label?.displayName, display)
			XCTAssertEqual(provenance, .checkpointIdentifier)
		}
	}

	/// A renamed file still gets its label, because the label was never in the filename.
	func test_theLabelComesFromTheCheckpointNotTheFilename() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		guard case .objectDetection(let model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("not recognised")
		}
		XCTAssertEqual(model.classLabel, .ringfort, "the fixture is named OD_ringfort.head.bin, but this came from the id")
	}

	func test_aStrippedIdentifier_yieldsAPlaceholder() {
		for identifier in [nil, "", "train_OD_SLRM_512px pretrained"] as [String?] {
			let (label, provenance) = ADAFCheckpointCatalog.classLabel(from: identifier)
			XCTAssertNil(label, "\(identifier ?? "nil")")
			XCTAssertEqual(provenance, .unnamed)
		}
	}

	/// Two class names in one identifier is ambiguous, and ambiguous resolves to nothing rather than
	/// to whichever appeared first.
	func test_anIdentifierNamingTwoClasses_isAmbiguousRatherThanFirstWins() {
		let (label, provenance) = ADAFCheckpointCatalog.classLabel(from: "train_barrow_and_ringfort_OD")
		XCTAssertNil(label)
		XCTAssertEqual(provenance, .unnamed)
	}

	/// The same class named twice is not ambiguous.
	func test_aRepeatedClassName_stillResolves() {
		let (label, _) = ADAFCheckpointCatalog.classLabel(from: "train_ringfort_OD_ringfort_v2")
		XCTAssertEqual(label, .ringfort)
	}

	/// Token matching, not substring matching: a class name inside a larger word is not a match.
	func test_aClassNameEmbeddedInAWord_isNotAMatch() {
		let (label, _) = ADAFCheckpointCatalog.classLabel(from: "train_ringfortress_OD")
		XCTAssertNil(label)
	}

	// MARK: - Nothing attacker-controlled reaches a message unbounded

	func test_theSummaryIsBoundedAndSanitised() {
		let hostile = [
			("\u{202E}gnihtemos.weight", [1]),
			(String(repeating: "A", count: 500) + ".weight", [1]),
			("nor\nmal.weight", [1]),
			("d.weight", [1]),
			("e.weight", [1]),
			("f.weight", [1])
		]
		let checkpoint = Self.checkpoint(tensors: hostile, identifier: nil)
		guard case .unrecognized(let summary) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("must not be recognised")
		}
		XCTAssertLessThanOrEqual(summary.topLevelPrefixes.count, 4)
		for prefix in summary.topLevelPrefixes {
			XCTAssertLessThanOrEqual(prefix.count, 24, prefix)
			XCTAssertTrue(
				prefix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") },
				"'\(prefix)' contains something that should not reach a message"
			)
		}
	}

	// MARK: - Helpers

	private static func checkpoint(tensors: [(String, [Int])], identifier: String?) -> PyTorchCheckpoint {
		PyTorchCheckpoint(
			root: "cp.pth",
			formatVersion: 3,
			identifier: identifier,
			epoch: 1,
			loss: 0,
			startTimestamp: 0,
			tensors: tensors.enumerated().map { index, tensor in
				PyTorchTensorRef(
					name: tensor.0,
					dataType: tensor.0.hasSuffix("num_batches_tracked") ? .int64 : .float32,
					shape: tensor.1,
					stride: [1],
					storageOffset: 0,
					storageKey: "\(index)",
					storageElementCount: tensor.1.reduce(1, *)
				)
			},
			totalStorageCount: tensors.count
		)
	}
}
