//
//  PyTorchCheckpointReaderTests.swift
//  NativeModelConverterTests
//
//  AIA-0666.
//

import XCTest
@testable import NativeModelConverter

final class PyTorchCheckpointReaderTests: XCTestCase {

	// MARK: - The real checkpoints, read end to end

	func test_theRealDetectionCheckpoint_readsItsWholeTensorTable() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))

		XCTAssertEqual(checkpoint.root, "best_checkpoint_1691592063_17.pth")
		XCTAssertEqual(checkpoint.formatVersion, 3)
		XCTAssertEqual(checkpoint.identifier, "train_ringfort_OD_SLRM_512px pretrained_train_12_val_124")
		XCTAssertEqual(checkpoint.epoch, 18)
		XCTAssertEqual(checkpoint.startTimestamp, 1_691_591_478)
		XCTAssertEqual(try XCTUnwrap(checkpoint.loss), 0.491_137_385_368_347_17, accuracy: 1e-15)
		XCTAssertEqual(checkpoint.tensors.count, 404)

		// 404 in the state_dict plus 528 the optimizer holds; the archive's other two entries are
		// data.pkl and version. This is the pickle and the container agreeing on the same file.
		XCTAssertEqual(checkpoint.totalStorageCount, 932)
	}

	func test_theRealSegmentationCheckpoint_readsToo() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("AO_HRNet"))
		XCTAssertEqual(checkpoint.root, "best_checkpoint_1698780271_45.pth")
		XCTAssertEqual(checkpoint.identifier, "train_AO_HRNet_SLRM_512px_pretrained_train_12_val_124_Transformation")
		XCTAssertEqual(checkpoint.epoch, 46)
		XCTAssertEqual(checkpoint.tensors.count, 1_964)
		XCTAssertEqual(checkpoint.totalStorageCount, 4_724)
	}

	/// The tensor table, checked field by field rather than by count. Names and shapes alone would let
	/// a wrong dtype, stride or storage key through, and those are what M3 will read bytes with.
	func test_theRealTensorTable_isCorrectInEveryField() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		let byName = Dictionary(uniqueKeysWithValues: checkpoint.tensors.map { ($0.name, $0) })

		let expected: [(String, PyTorchTensorDataType, [Int], [Int])] = [
			("backbone.body.conv1.weight", .float32, [64, 3, 7, 7], [147, 49, 7, 1]),
			("backbone.body.bn1.num_batches_tracked", .int64, [], []),
			("backbone.fpn.inner_blocks.0.1.weight", .float32, [256], [1]),
			("rpn.head.conv.0.0.weight", .float32, [256, 256, 3, 3], [2304, 9, 3, 1]),
			("rpn.head.cls_logits.weight", .float32, [3, 256, 1, 1], [256, 1, 1, 1]),
			("roi_heads.box_head.5.weight", .float32, [1024, 12544], [12544, 1]),
			("roi_heads.box_predictor.cls_score.weight", .float32, [2, 1024], [1024, 1]),
			("roi_heads.box_predictor.bbox_pred.bias", .float32, [8], [1])
		]
		for (name, dataType, shape, stride) in expected {
			let tensor = try XCTUnwrap(byName[name], "missing \(name)")
			XCTAssertEqual(tensor.dataType, dataType, name)
			XCTAssertEqual(tensor.shape, shape, name)
			XCTAssertEqual(tensor.stride, stride, name)
			XCTAssertEqual(tensor.storageOffset, 0, name)
		}

		let dataTypes = Dictionary(grouping: checkpoint.tensors, by: \.dataType).mapValues(\.count)
		XCTAssertEqual(dataTypes[.float32], 339)
		XCTAssertEqual(dataTypes[.int64], 65)
		XCTAssertEqual(checkpoint.tensors.reduce(0) { $0 + $1.elementCount }, 43_315_482)
	}

	/// The contiguity facts M3 will build on, asserted here so it inherits a checked fact rather than
	/// an assumption.
	func test_everyRealTensor_isContiguousAndCoversItsWholeStorage() throws {
		for id in ["OD_ringfort", "AO_HRNet"] {
			let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes(id))
			for tensor in checkpoint.tensors {
				XCTAssertTrue(tensor.isContiguousAndComplete, "\(id): \(tensor.name)")
			}
			XCTAssertEqual(Set(checkpoint.tensors.map(\.storageKey)).count, checkpoint.tensors.count,
						   "\(id): two tensors share a storage")
		}
	}

	// MARK: - What it does not read

	/// Two thirds of an ADAF checkpoint is optimizer state. It is counted, never located, and never
	/// read — and against the sparse fixture, reading it would fail loudly rather than pass silently.
	func test_theOptimizerIsCountedButNeverRead() throws {
		let bytes = try ADAFFixtures.sparseBytes("OD_ringfort")
		let counting = CountingBytes(bytes)
		let checkpoint = try PyTorchCheckpointReader.read(counting)

		XCTAssertEqual(checkpoint.totalStorageCount - checkpoint.tensors.count, 528, "the optimizer's storages")
		XCTAssertEqual(bytes.violations, [], "a read landed outside data.pkl, version and the directory")
		XCTAssertLessThan(counting.bytesRead, 1_024 * 1_024,
						  "read \(counting.bytesRead) bytes of a 517,823,445-byte checkpoint")
	}

	func test_readingIsBoundedForTheLargerSegmentationCheckpoint() throws {
		let bytes = try ADAFFixtures.sparseBytes("AO_HRNet")
		let counting = CountingBytes(bytes)
		_ = try PyTorchCheckpointReader.read(counting)
		XCTAssertEqual(counting.totalLength, 861_530_273)
		XCTAssertLessThan(counting.bytesRead, 2 * 1_024 * 1_024)
		XCTAssertEqual(bytes.violations, [])
	}

	// MARK: - The archive and the pickle must agree

	/// The in-file oracle. The pickle says a storage holds *n* elements of a type; the central
	/// directory says that entry is *m* bytes. Nothing in a test author's head is involved, so a wrong
	/// dtype size or a misread persistent id is caught by the file itself.
	func test_aStorageWhoseSizeContradictsTheArchive_isRefused() throws {
		var builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.oneTensorPickle(elements: 4), localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			// The pickle declares 4 float32 elements, so this entry must be 16 bytes. It is 12.
			.init(name: "cp.pth/data/0", payload: [UInt8](repeating: 0, count: 12))
		])
		builder.includeZip64Chain = true

		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(
				error as? PyTorchCheckpointError,
				.storageSizeDisagreesWithArchive(tensor: "w", declared: 16, archive: 12)
			)
		}
	}

	func test_aTensorWhoseStorageIsAbsent_isRefused() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.oneTensorPickle(elements: 4), localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(
				error as? PyTorchCheckpointError,
				.storageMissingFromArchive(tensor: "w", entry: "cp.pth/data/0")
			)
		}
	}

	/// A view reaching past the end of the storage it views. Nothing in the published checkpoints
	/// exercises this — every one of them is offset zero and contiguous — which is exactly why it is
	/// checked rather than assumed.
	func test_aTensorReachingPastItsStorage_isRefused() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl",
				  payload: Self.oneTensorPickle(elements: 4, shape: [4], storageOffset: 2),
				  localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			.init(name: "cp.pth/data/0", payload: [UInt8](repeating: 0, count: 16))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .tensorOutsideItsStorage(tensor: "w"))
		}
	}

	// MARK: - Arithmetic that must refuse rather than abort

	/// The crash both reviewers found. `shape.reduce(1, *)` traps on overflow, and a trap is a process
	/// abort that no `catch` above can turn into a refused import — so a pasted URL could kill the app.
	/// Dimensions are attacker-chosen and were guarded only `>= 0`.
	func test_aShapeWhoseProductOverflows_isRefusedRatherThanTrapping() throws {
		var program = PickleProgram()
		program.emptyDict()
		program.string("state_dict")
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.string("w")
		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: 1)
		program.int1(0)
		program.mark(); program.int4(2_147_483_647); program.int4(2_147_483_647); program.int4(2_147_483_647); program.tuple()
		program.mark(); program.int1(1); program.int1(1); program.int1(1); program.tuple()
		program.newFalse()
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.tuple(); program.reduce()
		program.setItem(); program.setItem(); program.stop()

		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: program.bytes, localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			.init(name: "cp.pth/data/0", payload: [0, 0, 0, 0])
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			guard case .unreadablePickle = try? XCTUnwrap(error as? PyTorchCheckpointError) else {
				return XCTFail("got \(error)")
			}
		}
	}

	/// `elementCount` must saturate rather than trap even when the value is built directly, because the
	/// type is public and a future caller need not come through the decoder.
	func test_anOverflowingShapeSaturatesInsteadOfTrapping() {
		let reference = PyTorchTensorRef(
			name: "w", dataType: .float32,
			shape: [Int.max, 2], stride: [1, 1], storageOffset: 0,
			storageKey: "0", storageElementCount: 4
		)
		XCTAssertEqual(reference.elementCount, .max)
		XCTAssertFalse(reference.isContiguousAndComplete)
	}

	/// A view that is strided rather than contiguous addresses memory far beyond what its element
	/// count suggests: shape [2, 2] with stride [100, 1] holds four elements but reaches index 101.
	func test_aStridedViewIsRefusedEvenThoughItsElementCountFits() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl",
				  payload: Self.oneTensorPickle(elements: 4, shape: [2, 2], stride: [100, 1]),
				  localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			.init(name: "cp.pth/data/0", payload: [UInt8](repeating: 0, count: 16))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .tensorIsNotContiguous(tensor: "w"))
		}
	}

	// MARK: - One storage cannot be two things

	/// Two tensors naming the same blob with different dtypes: one eight-byte entry satisfies
	/// `2 x float32` and `1 x int64` alike, so the per-tensor size check passes twice while the reader
	/// holds contradictory descriptions of a single storage.
	func test_twoTensorsDescribingOneStorageDifferently_areRefused() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.twoTensorsSharingAStoragePickle(), localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			.init(name: "cp.pth/data/0", payload: [UInt8](repeating: 0, count: 8))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .storageDescribedInconsistently(key: "0"))
		}
	}

	/// The doc comment used to say the storage count was checked against the archive. It was counted
	/// and never compared; now it is.
	func test_aPickleReferencingFewerStoragesThanTheArchiveCarries_isRefused() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.oneTensorPickle(elements: 4), localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8)),
			.init(name: "cp.pth/data/0", payload: [UInt8](repeating: 0, count: 16)),
			.init(name: "cp.pth/data/1", payload: [UInt8](repeating: 0, count: 16))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError,
						   .storageCountDisagreesWithArchive(pickle: 1, archive: 2))
		}
	}

	/// The real files satisfy it: 932 persistent ids against 932 `data/<n>` entries.
	func test_theRealCheckpointsAgreeOnTheirStorageCount() throws {
		for (id, expected) in [("OD_ringfort", 932), ("AO_HRNet", 4_724)] {
			let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes(id))
			XCTAssertEqual(checkpoint.totalStorageCount, expected, id)
		}
	}

	// MARK: - Shape of the file

	func test_aCheckpointWithNoStateDictionary_isRefused() throws {
		var program = PickleProgram()
		program.emptyDict()
		program.string("epoch")
		program.int1(1)
		program.setItem()
		program.stop()
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: program.bytes, localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .missingStateDictionary)
		}
	}

	func test_anUnknownSerializationVersion_isRefusedByNumber() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.oneTensorPickle(elements: 4), localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("7\n".utf8))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .unsupportedFormatVersion(7))
		}
	}

	func test_aCheckpointWithNoVersionEntry_isRefused() throws {
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: Self.oneTensorPickle(elements: 4), localExtraLength: 56)
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			XCTAssertEqual(error as? PyTorchCheckpointError, .missingVersion)
		}
	}

	/// A pickle refusal must surface as a checkpoint refusal, not escape as a decoder error the app
	/// has never heard of.
	func test_aHostilePickle_surfacesAsAnUnreadablePickle() throws {
		var program = PickleProgram()
		program.global("posix", "system")
		program.stop()
		let builder = TestZipBuilder(entries: [
			.init(name: "cp.pth/data.pkl", payload: program.bytes, localExtraLength: 56),
			.init(name: "cp.pth/version", payload: Array("3\n".utf8))
		])
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes(builder.build()))) { error in
			guard case .unreadablePickle = try? XCTUnwrap(error as? PyTorchCheckpointError) else {
				return XCTFail("got \(error)")
			}
		}
	}

	func test_bytesThatAreNotAnArchive_surfaceAsAnUnreadableArchive() throws {
		XCTAssertThrowsError(try PyTorchCheckpointReader.read(ArrayBytes([UInt8](repeating: 0x2A, count: 512)))) { error in
			guard case .unreadableArchive = try? XCTUnwrap(error as? PyTorchCheckpointError) else {
				return XCTFail("got \(error)")
			}
		}
	}

	// MARK: - Helpers

	/// Two tensors whose persistent ids name the same storage key with different dtypes.
	private static func twoTensorsSharingAStoragePickle() -> [UInt8] {
		var program = PickleProgram()
		program.emptyDict()
		program.string("state_dict")
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		for (name, kind, count) in [("a", "FloatStorage", UInt8(2)), ("b", "LongStorage", UInt8(1))] {
			program.string(name)
			program.global("torch._utils", "_rebuild_tensor_v2")
			program.mark()
			program.storage(kind: kind, key: "0", count: count)
			program.int1(0)
			program.mark(); program.int1(count); program.tuple()
			program.mark(); program.int1(1); program.tuple()
			program.newFalse()
			program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
			program.tuple(); program.reduce()
			program.setItem()
		}
		program.setItem()
		program.stop()
		return program.bytes
	}

	/// `{"state_dict": OrderedDict([("w", tensor)])}` with one float32 tensor.
	private static func oneTensorPickle(
		elements: UInt8, shape: [UInt8]? = nil, stride: [UInt8]? = nil, storageOffset: UInt8 = 0
	) -> [UInt8] {
		var program = PickleProgram()
		program.emptyDict()
		program.string("state_dict")

		program.global("collections", "OrderedDict")
		program.emptyTuple()
		program.reduce()
		program.string("w")

		program.global("torch._utils", "_rebuild_tensor_v2")
		program.mark()
		program.storage(key: "0", count: elements)
		program.int1(storageOffset)
		program.mark()
		for dimension in shape ?? [elements] { program.int1(dimension) }
		program.tuple()
		program.mark()
		for step in stride ?? [1] { program.int1(step) }
		program.tuple()
		program.newFalse()
		program.global("collections", "OrderedDict"); program.emptyTuple(); program.reduce()
		program.tuple()
		program.reduce()

		program.setItem()
		program.setItem()
		program.stop()
		return program.bytes
	}
}
