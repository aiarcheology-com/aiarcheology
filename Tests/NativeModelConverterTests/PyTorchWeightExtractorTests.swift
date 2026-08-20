//
//  PyTorchWeightExtractorTests.swift
//  NativeModelConverterTests
//
//  AIA-0675.
//

import CryptoKit
import XCTest
@testable import NativeModelConverter

/// The storages of `OD_ringfort` that lie **wholly** inside the committed head fixture.
///
/// Measured against the real central directory, not chosen. Entries are written in name order, so
/// after `data/101` (which ends at 153,096) comes `data/102`, 262,144 bytes on its own — which is
/// why the head is 163,840 bytes and not more. Every byte the fixture grew past the 131,072 it
/// carried for AIA-0666 buys one of these five storages; growing it further would only widen the
/// window in which a stray read stops being a `SparseFixtureBytes` violation.
///
/// If this list ever stops matching the fixture, `SparseFixtureBytes` fails the test at the read
/// site rather than letting a zero-filled "weight" through.
private let committedStorageKeys: Set<String> = ["0", "1", "10", "100", "101"]

/// `backbone.body.conv1.weight`, first eight and last four elements, as fp16 bit patterns.
///
/// **These are the out-of-band oracle, and the reason this file can claim to verify anything.**
/// Everything else a test here could compare against is derived from the same archive by the same
/// code under test, so a self-consistent misreading — swapped endianness, a storage mapped to the
/// wrong name, elements in the wrong order, a rounding mode that is nearly right — would agree with
/// itself and pass. These values were produced outside this repository, by CPython: its own
/// `pickle` to find which storage `backbone.body.conv1.weight` names, its own `struct` to decode
/// little-endian fp32, and its own `struct '<e'` to round to IEEE-754 half. Three independent
/// implementations of the three things this extractor could get wrong.
///
/// Note `0x8057` among the tail values: a negative fp16 **subnormal** (-5.196e-06 rounds to
/// -5.185e-06), so the rounding path below the normal range is pinned too.
private let conv1FirstEightFloat16Bits: [UInt16] = [0x9E42, 0x20E5, 0x280A, 0xA653, 0xB094, 0x2A23, 0x2742, 0xA165]
private let conv1LastFourFloat16Bits: [UInt16] = [0x2640, 0x8057, 0x9C40, 0x28DA]

/// The digest the head fixture carried when AIA-0666 committed it, over its first 131,072 bytes.
///
/// Pinned as a literal here on purpose. The manifest's digest is regenerated in the same commit that
/// re-cuts the fixture, so asserting against it proves only that the two were written together. This
/// value predates the re-cut and cannot be regenerated from it, which makes "the bytes AIA-0666
/// verified are still the bytes at the front of this file" a fact rather than a claim.
private let originalHeadPrefixSHA256 = "a8874aab0ee18b714e1984bbfb9b6c5be1fb4cd6aba02ce373aea468cab6a148"

final class PyTorchWeightExtractorTests: XCTestCase {

	// MARK: - The real bytes (always on, no download, no environment variable)

	/// The point of the whole slice: real published weights reach a `NativeModelWeight` blob.
	///
	/// The oracle is not a golden file. Each extracted tensor is compared against the same bytes read
	/// through ``PyTorchZipArchive/bytes(of:maximumByteCount:)`` — a whole-entry read whose CRC-32 is
	/// checked against the publisher's central directory — so what is asserted is that the streamed,
	/// chunked, fp16-converting path agrees with an independently checksummed read of the same file.
	func test_realCheckpoint_weightsReachTheBlobAndMatchTheirPublishedBytes() throws {
		let source = try ADAFFixtures.sparseBytes("OD_ringfort")
		let checkpoint = try PyTorchCheckpointReader.read(source)
		let covered = try XCTUnwrap(trimmed(checkpoint, to: committedStorageKeys))

		let destination = temporaryFileURL()
		let extraction = try PyTorchWeightExtractor.extract(covered, from: source, to: destination)

		XCTAssertEqual(source.violations, [], "extraction read outside the committed fixture regions")
		XCTAssertEqual(
			extraction.weights.map(\.name),
			[
				"backbone.body.conv1.weight",
				"backbone.body.bn1.weight",
				"backbone.body.layer1.0.bn1.running_var",
				"backbone.body.layer2.1.bn2.running_var"
			],
			"weights must come out in state_dict order — the model's layer order"
		)
		XCTAssertEqual(
			extraction.skippedCounterTensors,
			["backbone.body.layer2.1.bn2.num_batches_tracked"],
			"the int64 counter has no float16 representation and must be named, not silently dropped"
		)

		let blob = try Data(contentsOf: destination)
		XCTAssertEqual(UInt64(blob.count), extraction.byteCount)
		XCTAssertEqual(extraction.byteCount, (9408 + 64 + 64 + 128) * 2, "one fp16 per element, no padding")
		XCTAssertEqual(extraction.sourceByteCount, extraction.byteCount * 2, "fp32 in, fp16 out")

		let archive = try PyTorchZipArchive.open(source)
		var expectedOffset: UInt64 = 0
		for (weight, key) in zip(extraction.weights, ["0", "1", "10", "100"]) {
			XCTAssertEqual(weight.offset, expectedOffset, "\(weight.name) is not where the previous weight ended")
			XCTAssertEqual(weight.dataType, .float16)

			// A second, independent read of the same storage: whole-entry rather than streamed, and
			// CRC-32 checked against the publisher's central directory on the way. This catches
			// chunk-stitching, not misinterpretation — the literals below catch that.
			let entry = try XCTUnwrap(archive.entry(named: "\(checkpoint.root)/data/\(key)"))
			let published = try archive.bytes(of: entry, maximumByteCount: 1 << 20)
			let expected = float16Bytes(fromLittleEndianFloat32: published)
			let actual = [UInt8](blob[Int(weight.offset)..<Int(weight.offset + weight.byteCount)])
			XCTAssertEqual(actual, expected, "\(weight.name) does not match its published bytes")
			expectedOffset += weight.byteCount
		}

		XCTAssertEqual(
			float16Bits(of: blob, from: 0, count: 8), conv1FirstEightFloat16Bits,
			"conv1.weight's leading values do not match the values CPython reads out of this file"
		)
		XCTAssertEqual(
			float16Bits(of: blob, from: (9408 - 4) * 2, count: 4), conv1LastFourFloat16Bits,
			"conv1.weight's trailing values do not match — the tensor is the wrong length or order"
		)
		XCTAssertEqual(
			extraction.weights.count + extraction.skippedCounterTensors.count,
			covered.tensors.count,
			"every tensor must be written or named as skipped; nothing may simply disappear"
		)
		XCTAssertEqual(
			extraction.sha256, sha256Hex([UInt8](blob)),
			"the digest is computed in the extraction pass and must equal the file's"
		)
		XCTAssertNotNil(extraction.memory, "the extraction must report the footprint it was measured at")
		try? FileManager.default.removeItem(at: destination)
	}

	/// The head fixture grew for this ticket. What AIA-0666 committed must still be at the front of
	/// it, byte for byte, or every read set that suite pinned is measuring a different file.
	func test_theCommittedHead_stillStartsWithTheBytesTheReaderSuiteWasWrittenAgainst() throws {
		let model = try ADAFFixtures.model("OD_ringfort")
		let head = try XCTUnwrap(model.head)
		XCTAssertEqual(head.offset, 0)
		XCTAssertEqual(head.length, 163_840, "the head is sized to reach data/101 and no further")

		let url = try XCTUnwrap(Bundle.module.url(forResource: "OD_ringfort.head", withExtension: "bin"))
		let bytes = [UInt8](try Data(contentsOf: url))
		XCTAssertEqual(bytes.count, head.length)
		XCTAssertEqual(sha256Hex(Array(bytes[0..<131_072])), originalHeadPrefixSHA256)
	}

	/// The first real weight, spelled out. A shape or an element count that silently changed would
	/// otherwise be invisible behind a byte comparison that changed with it.
	func test_realCheckpoint_theFirstConvolutionKeepsItsShape() throws {
		let source = try ADAFFixtures.sparseBytes("OD_ringfort")
		let checkpoint = try PyTorchCheckpointReader.read(source)
		let covered = try XCTUnwrap(trimmed(checkpoint, to: committedStorageKeys))

		let destination = temporaryFileURL()
		let extraction = try PyTorchWeightExtractor.extract(covered, from: source, to: destination)
		defer { try? FileManager.default.removeItem(at: destination) }

		let convolution = try XCTUnwrap(extraction.weights.first)
		XCTAssertEqual(convolution.name, "backbone.body.conv1.weight")
		XCTAssertEqual(convolution.shape, [64, 3, 7, 7])
		XCTAssertEqual(convolution.byteCount, 9408 * 2)
		XCTAssertEqual(convolution.offset, 0)
	}

	// MARK: - Refusals and mechanics (built archives — see TestZipBuilder's note)

	/// Chunking is the part most able to be subtly wrong: a float straddling a chunk boundary shifts
	/// every later value by a byte and still produces a blob of exactly the right length. Asserted
	/// differentially — the streamed conversion against the same input converted in one pass.
	func test_aStorageLargerThanOneChunk_convertsIdenticallyToOnePass() throws {
		let elementCount = PyTorchWeightExtractor.chunkByteCount / 4 + 12_345
		let values = (0..<elementCount).map { Float($0 % 2_048) * 0.125 - 128 }
		let payload = littleEndianFloat32Bytes(values)
		XCTAssertGreaterThan(payload.count, PyTorchWeightExtractor.chunkByteCount, "the test tensor must span chunks")

		let (checkpoint, source) = archive(holding: payload, shape: [elementCount])
		let destination = temporaryFileURL()
		let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)
		defer { try? FileManager.default.removeItem(at: destination) }

		let blob = [UInt8](try Data(contentsOf: destination))
		XCTAssertEqual(blob, float16Bytes(fromLittleEndianFloat32: payload))
		XCTAssertEqual(extraction.byteCount, UInt64(elementCount * 2))
	}

	/// fp16 tops out around 65,504. Clamping a larger weight to infinity would poison every product
	/// it enters while leaving a blob of exactly the expected length, so it is refused by name.
	func test_aWeightTooLargeForFloat16_isRefusedNamingTheTensor() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 1e30, 4])
		let (checkpoint, source) = archive(holding: payload, shape: [4])
		let destination = temporaryFileURL()

		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)) {
			XCTAssertEqual(
				$0 as? PyTorchWeightExtractionError,
				.valueNotRepresentableInFloat16(tensor: "layer.weight")
			)
		}
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: destination.path),
			"a partial blob must not survive a failed extraction"
		)
	}

	/// Values that merely lose precision are accepted: that is what storing fp16 means.
	func test_aWeightThatUnderflowsToZero_isAcceptedAsOrdinaryPrecisionLoss() throws {
		let payload = littleEndianFloat32Bytes([1e-30, 0.5])
		let (checkpoint, source) = archive(holding: payload, shape: [2])
		let destination = temporaryFileURL()
		let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)
		defer { try? FileManager.default.removeItem(at: destination) }

		XCTAssertEqual(extraction.weights.count, 1)
		XCTAssertEqual([UInt8](try Data(contentsOf: destination)), float16Bytes(fromLittleEndianFloat32: payload))
	}

	/// The checksum is what makes "the bytes we wrote are the bytes the publisher wrote" a fact
	/// rather than a hope, and it is only known after the last chunk has already been handed over.
	func test_aStorageFailingItsChecksum_isRefusedAndLeavesNoBlob() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 3, 4])
		var builder = TestZipBuilder.torchLike()
		builder.entries.append(
			TestZipBuilder.Entry(name: "checkpoint.pth/data/0", payload: payload, overrideCRC: 0xDEAD_BEEF)
		)
		let source = ArrayBytes(builder.build())
		let checkpoint = handMadeCheckpoint(shape: [4], elementCount: 4)
		let destination = temporaryFileURL()

		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)) {
			XCTAssertEqual($0 as? PyTorchWeightExtractionError, .storageChecksumFailed(tensor: "layer.weight"))
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	/// The counter skip is narrow on purpose: an integer tensor that is *not* the BatchNorm counter
	/// would otherwise vanish from a future checkpoint with nothing to show it ever existed.
	func test_anIntegerTensorThatIsNotABatchNormCounter_isRefusedRatherThanSkipped() throws {
		let payload = [UInt8](repeating: 0, count: 8)
		let (_, source) = archive(holding: payload, shape: [1])
		let checkpoint = PyTorchCheckpoint(
			root: "checkpoint.pth", formatVersion: 3, identifier: nil, epoch: nil, loss: nil,
			startTimestamp: nil,
			tensors: [
				PyTorchTensorRef(
					name: "head.class_index", dataType: .int64, shape: [1], stride: [1],
					storageOffset: 0, storageKey: "0", storageElementCount: 1
				)
			],
			totalStorageCount: 1,
			pickleChecksum: builtPickleChecksum
		)
		let destination = temporaryFileURL()

		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)) {
			XCTAssertEqual(
				$0 as? PyTorchWeightExtractionError,
				.unrepresentableTensor(tensor: "head.class_index", dataType: "int64")
			)
		}
	}

	/// The failure no other check here can see: a description decoded from one file, extracted from
	/// another. The four published detectors have byte-identical tensor tables, so names, shapes,
	/// storage keys, entry sizes and per-entry CRCs all agree across them — every assertion in this
	/// file would stay green while the weights came from a different model.
	func test_aCheckpointDecodedFromAnotherArchive_isRefusedBeforeAnyByteIsWritten() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 3, 4])
		var other = TestZipBuilder.torchLike(pickle: [0x80, 0x02, 0x4E, 0x2E])
		other.entries.append(TestZipBuilder.Entry(name: "checkpoint.pth/data/0", payload: payload))
		let source = ArrayBytes(other.build())
		let destination = temporaryFileURL()

		XCTAssertThrowsError(
			try PyTorchWeightExtractor.extract(handMadeCheckpoint(shape: [4], elementCount: 4), from: source, to: destination)
		) {
			XCTAssertEqual($0 as? PyTorchWeightExtractionError, .checkpointDescribesAnotherArchive)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	/// The reader already refuses strided views, but this code can be handed a checkpoint it did not
	/// read, and a strided tensor copied flat is silently the wrong weight.
	func test_aStridedTensor_isRefused() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 3, 4])
		let (_, source) = archive(holding: payload, shape: [4])
		let strided = PyTorchCheckpoint(
			root: "checkpoint.pth",
			formatVersion: 3,
			identifier: nil,
			epoch: nil,
			loss: nil,
			startTimestamp: nil,
			tensors: [
				PyTorchTensorRef(
					name: "layer.weight", dataType: .float32, shape: [2], stride: [2],
					storageOffset: 0, storageKey: "0", storageElementCount: 4
				)
			],
			totalStorageCount: 1,
			pickleChecksum: builtPickleChecksum
		)
		let destination = temporaryFileURL()

		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(strided, from: source, to: destination)) {
			XCTAssertEqual($0 as? PyTorchWeightExtractionError, .tensorIsNotContiguous(tensor: "layer.weight"))
		}
	}

	/// A checkpoint and an archive are two independent statements about the same bytes. When the
	/// shape implies one length and the entry is another, copying either one writes a tensor that is
	/// not the tensor being named.
	func test_aStorageThatIsNotTheSizeTheShapeImplies_isRefused() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 3, 4])
		let (_, source) = archive(holding: payload, shape: [4])
		let destination = temporaryFileURL()

		XCTAssertThrowsError(
			try PyTorchWeightExtractor.extract(handMadeCheckpoint(shape: [8], elementCount: 8), from: source, to: destination)
		) {
			XCTAssertEqual(
				$0 as? PyTorchWeightExtractionError,
				.storageSizeDisagreesWithArchive(tensor: "layer.weight", expected: 32, archive: 16)
			)
		}
	}

	func test_aTensorWhoseStorageIsNotInTheArchive_isRefusedNamingTheEntry() throws {
		let payload = littleEndianFloat32Bytes([1, 2, 3, 4])
		let (_, source) = archive(holding: payload, shape: [4])
		var checkpoint = handMadeCheckpoint(shape: [4], elementCount: 4)
		checkpoint = PyTorchCheckpoint(
			root: checkpoint.root, formatVersion: 3, identifier: nil, epoch: nil, loss: nil,
			startTimestamp: nil,
			tensors: [
				PyTorchTensorRef(
					name: "layer.weight", dataType: .float32, shape: [4], stride: [1],
					storageOffset: 0, storageKey: "77", storageElementCount: 4
				)
			],
			totalStorageCount: 1,
			pickleChecksum: builtPickleChecksum
		)
		let destination = temporaryFileURL()

		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(checkpoint, from: source, to: destination)) {
			XCTAssertEqual(
				$0 as? PyTorchWeightExtractionError,
				.storageMissingFromArchive(tensor: "layer.weight", entry: "checkpoint.pth/data/77")
			)
		}
	}

	// MARK: - Helpers

	private func trimmed(_ checkpoint: PyTorchCheckpoint, to storageKeys: Set<String>) -> PyTorchCheckpoint? {
		let tensors = checkpoint.tensors.filter { storageKeys.contains($0.storageKey) }
		guard tensors.count == storageKeys.count else { return nil }
		return PyTorchCheckpoint(
			root: checkpoint.root,
			formatVersion: checkpoint.formatVersion,
			identifier: checkpoint.identifier,
			epoch: checkpoint.epoch,
			loss: checkpoint.loss,
			startTimestamp: checkpoint.startTimestamp,
			tensors: tensors,
			totalStorageCount: checkpoint.totalStorageCount,
			pickleChecksum: checkpoint.pickleChecksum
		)
	}

	private func handMadeCheckpoint(shape: [Int], elementCount: Int) -> PyTorchCheckpoint {
		PyTorchCheckpoint(
			root: "checkpoint.pth",
			formatVersion: 3,
			identifier: nil,
			epoch: nil,
			loss: nil,
			startTimestamp: nil,
			tensors: [
				PyTorchTensorRef(
					name: "layer.weight", dataType: .float32, shape: shape,
					stride: contiguousStride(for: shape), storageOffset: 0,
					storageKey: "0", storageElementCount: elementCount
				)
			],
			totalStorageCount: 1,
			pickleChecksum: builtPickleChecksum
		)
	}

	private func archive(holding payload: [UInt8], shape: [Int]) -> (PyTorchCheckpoint, ArrayBytes) {
		var builder = TestZipBuilder.torchLike()
		builder.entries.append(TestZipBuilder.Entry(name: "checkpoint.pth/data/0", payload: payload))
		let elementCount = shape.reduce(1, *)
		return (handMadeCheckpoint(shape: shape, elementCount: elementCount), ArrayBytes(builder.build()))
	}

	private func contiguousStride(for shape: [Int]) -> [Int] {
		var stride = [Int](repeating: 1, count: shape.count)
		for index in stride.indices.dropLast().reversed() {
			stride[index] = stride[index + 1] * shape[index + 1]
		}
		return stride
	}

	/// The checksum `TestZipBuilder.torchLike()` records for its `data.pkl`, which is what binds a
	/// hand-made checkpoint description to a built archive.
	private var builtPickleChecksum: UInt32 { CRC32.checksum([0x80, 0x02, 0x2E]) }

	private func temporaryFileURL() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("weights-\(UUID().uuidString).bin", isDirectory: false)
	}

	private func littleEndianFloat32Bytes(_ values: [Float]) -> [UInt8] {
		values.flatMap { value -> [UInt8] in
			let bits = value.bitPattern
			return (0..<4).map { UInt8((bits >> ($0 * 8)) & 0xFF) }
		}
	}

	/// The conversion written a second time, in one pass, for the streamed path to be compared
	/// against. Deliberately not shared with the implementation.
	private func float16Bits(of blob: Data, from offset: Int, count: Int) -> [UInt16] {
		(0..<count).map { index in
			let base = blob.startIndex + offset + index * 2
			return UInt16(blob[base]) | UInt16(blob[base + 1]) << 8
		}
	}

	private func sha256Hex(_ bytes: [UInt8]) -> String {
		SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
	}

	private func float16Bytes(fromLittleEndianFloat32 bytes: [UInt8]) -> [UInt8] {
		stride(from: 0, to: bytes.count, by: 4).flatMap { index -> [UInt8] in
			let bits = UInt32(bytes[index])
				| UInt32(bytes[index + 1]) << 8
				| UInt32(bytes[index + 2]) << 16
				| UInt32(bytes[index + 3]) << 24
			let half = Float16(Float(bitPattern: bits)).bitPattern
			return [UInt8(half & 0xFF), UInt8(half >> 8)]
		}
	}
}
