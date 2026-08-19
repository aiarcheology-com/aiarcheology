//
//  PyTorchZipArchiveTests.swift
//  NativeModelConverterTests
//
//  AIA-0666.
//

import XCTest
@testable import NativeModelConverter

/// Builds zip archives shaped like the ones `torch.save` writes, so a test can mutate one field at
/// a time and see which refusal fires.
///
/// Every value it defaults to was measured on a real ADAF checkpoint: entries stored, flags `0x0808`,
/// local headers with zeroed sizes and alignment padding in their extra field, a central directory
/// with no extra field at all, and the ZIP64 record + locator that torch writes even for archives
/// that do not need them.
///
/// - Note: this is only ever used for **refusals**. Positive paths are asserted against the committed
///   real bytes, because a builder written from the same beliefs as the reader would agree with it
///   whether or not either matched a real file — which is precisely how AIA-0654 shipped a sniffer
///   that could not read the file it was written for.
struct TestZipBuilder {
	struct Entry {
		var name: String
		var payload: [UInt8]
		/// Padding written into the *local* extra field, as torch does to align payloads. Deliberately
		/// unrelated to the central record's extra length, which stays zero.
		var localExtraLength: Int = 0
		var flags: UInt16 = 0x0808
		var method: UInt16 = 0
		var overrideCRC: UInt32?
		var overrideCentralSize: UInt32?
		var overrideLocalName: String?
		var centralExtra: [UInt8] = []
	}

	var entries: [Entry] = []
	var includeZip64Chain = true
	var comment: [UInt8] = []
	var prefix: [UInt8] = []
	/// Padding inserted between the central directory and the ZIP64 record, breaking the chain that
	/// ties the directory's recorded location to the tail structures while leaving both valid.
	var gapBeforeZip64Chain = 0
	/// Overrides written into the classic end record after it is otherwise built correctly.
	var overrideEntryCount: UInt16?
	var overrideDirectorySize: UInt32?
	var overrideDirectoryOffset: UInt32?
	var overrideZip64EntryCount: UInt64?

	func build() -> [UInt8] {
		var bytes = prefix
		var localOffsets: [Int] = []

		for entry in entries {
			localOffsets.append(bytes.count)
			let nameBytes = Array((entry.overrideLocalName ?? entry.name).utf8)
			bytes += le32(0x0403_4B50)
			bytes += le16(20) + le16(entry.flags) + le16(entry.method)
			bytes += le16(0) + le16(0)
			// Zeroed here exactly as torch writes them: the data-descriptor bit puts the real values
			// in the central directory.
			bytes += le32(0) + le32(0) + le32(0)
			bytes += le16(UInt16(nameBytes.count)) + le16(UInt16(entry.localExtraLength))
			bytes += nameBytes
			bytes += [UInt8](repeating: 0, count: entry.localExtraLength)
			bytes += entry.payload
		}

		let directoryOffset = bytes.count
		for (index, entry) in entries.enumerated() {
			let nameBytes = Array(entry.name.utf8)
			let size = entry.overrideCentralSize ?? UInt32(entry.payload.count)
			bytes += le32(0x0201_4B50)
			bytes += le16(20) + le16(20) + le16(entry.flags) + le16(entry.method)
			bytes += le16(0) + le16(0)
			bytes += le32(entry.overrideCRC ?? CRC32.checksum(entry.payload))
			bytes += le32(size) + le32(size)
			bytes += le16(UInt16(nameBytes.count)) + le16(UInt16(entry.centralExtra.count)) + le16(0)
			bytes += le16(0) + le16(0) + le32(0)
			bytes += le32(UInt32(localOffsets[index]))
			bytes += nameBytes + entry.centralExtra
		}
		let directorySize = bytes.count - directoryOffset

		bytes += [UInt8](repeating: 0x00, count: gapBeforeZip64Chain)

		if includeZip64Chain {
			let recordOffset = bytes.count
			bytes += le32(0x0606_4B50)
			bytes += le64(44)
			bytes += le16(45) + le16(45)
			bytes += le32(0) + le32(0)
			let count = overrideZip64EntryCount ?? UInt64(entries.count)
			bytes += le64(count) + le64(count)
			bytes += le64(UInt64(directorySize)) + le64(UInt64(directoryOffset))
			bytes += le32(0x0706_4B50)
			bytes += le32(0) + le64(UInt64(recordOffset)) + le32(1)
		}

		bytes += le32(0x0605_4B50)
		bytes += le16(0) + le16(0)
		let count = overrideEntryCount ?? UInt16(entries.count)
		bytes += le16(count) + le16(count)
		bytes += le32(overrideDirectorySize ?? UInt32(directorySize))
		bytes += le32(overrideDirectoryOffset ?? UInt32(directoryOffset))
		bytes += le16(UInt16(comment.count))
		bytes += comment
		return bytes
	}

	/// A minimal archive with the torch layout: a `data.pkl` under a single root, plus `version`.
	static func torchLike(root: String = "checkpoint.pth", pickle: [UInt8] = [0x80, 0x02, 0x2E]) -> TestZipBuilder {
		TestZipBuilder(entries: [
			Entry(name: "\(root)/data.pkl", payload: pickle, localExtraLength: 56),
			Entry(name: "\(root)/version", payload: Array("3\n".utf8), localExtraLength: 41)
		])
	}

	private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
	private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
	private func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
}

final class PyTorchZipArchiveTests: XCTestCase {

	// MARK: - The real bytes (always on, no download, no environment variable)

	/// The assertion the milestone exists for: the reader opens a real ADAF checkpoint.
	func test_realCheckpoint_opensAndReportsItsEntries() throws {
		let bytes = try ADAFFixtures.sparseBytes("OD_ringfort")
		let archive = try PyTorchZipArchive.open(bytes)

		XCTAssertEqual(archive.entries.count, 934)
		XCTAssertEqual(bytes.violations, [], "the reader touched bytes outside its declared read set")

		let (root, pickle) = try archive.torchPickleEntry()
		XCTAssertEqual(root, "best_checkpoint_1691592063_17.pth")
		XCTAssertEqual(pickle.uncompressedSize, 113_659)
		XCTAssertEqual(pickle.crc32, 0xd97a_5c99)
		XCTAssertEqual(pickle.localHeaderOffset, 0)

		let version = try XCTUnwrap(archive.entry(named: "\(root)/version"))
		XCTAssertEqual(version.uncompressedSize, 2)
	}

	func test_realSegmentationCheckpoint_opensToo() throws {
		let bytes = try ADAFFixtures.sparseBytes("AO_HRNet")
		let archive = try PyTorchZipArchive.open(bytes)

		XCTAssertEqual(archive.entries.count, 4_726)
		let (root, pickle) = try archive.torchPickleEntry()
		XCTAssertEqual(root, "best_checkpoint_1698780271_45.pth")
		XCTAssertEqual(pickle.uncompressedSize, 621_064)
		XCTAssertEqual(pickle.crc32, 0x2ddc_c15d)
		XCTAssertEqual(bytes.violations, [])
	}

	/// Reading the pickle resolves a local header — the one place this reader is allowed to — and the
	/// payload's checksum must match the directory record that pointed at it.
	func test_realPickle_isReadAndItsChecksumChecks() throws {
		let bytes = try ADAFFixtures.sparseBytes("OD_ringfort")
		let archive = try PyTorchZipArchive.open(bytes)
		let (_, pickle) = try archive.torchPickleEntry()

		let payload = try archive.bytes(of: pickle, maximumByteCount: 8 * 1024 * 1024)
		XCTAssertEqual(payload.count, 113_659)
		XCTAssertEqual(Array(payload.prefix(2)), [0x80, 0x02], "protocol 2 pickle")
		XCTAssertEqual(bytes.violations, [])
	}

	/// The measured fact that would have sunk a reader resolving offsets from the central directory:
	/// `data.pkl`'s local extra field is 56 bytes where its central one is zero, which is what places
	/// the payload at the 64-byte-aligned offset 128.
	func test_realPickle_payloadSitsPastTheLocalExtraField() throws {
		let bytes = try ADAFFixtures.sparseBytes("OD_ringfort")
		let header = try bytes.readChecked(at: 0, count: 30)
		let nameLength = Int(header[26]) | (Int(header[27]) << 8)
		let extraLength = Int(header[28]) | (Int(header[29]) << 8)
		XCTAssertEqual(nameLength, 42)
		XCTAssertEqual(extraLength, 56, "torch pads the local extra field to align the payload")
		XCTAssertEqual(30 + nameLength + extraLength, 128)
		XCTAssertEqual(128 % 64, 0)
	}

	/// A 518 MB archive must cost kilobytes. The budget is the whole reason the reader is shaped the
	/// way it is, so it is asserted rather than described.
	func test_openingAndReadingTheRealCheckpoint_staysWellUnderAMegabyte() throws {
		let sparse = try ADAFFixtures.sparseBytes("OD_ringfort")
		let counting = CountingBytes(sparse)
		let archive = try PyTorchZipArchive.open(counting)
		let (_, pickle) = try archive.torchPickleEntry()
		_ = try archive.bytes(of: pickle, maximumByteCount: 8 * 1024 * 1024)

		XCTAssertEqual(counting.totalLength, 517_823_445)
		XCTAssertLessThan(counting.bytesRead, 1_024 * 1_024,
						  "read \(counting.bytesRead) bytes of a 517,823,445-byte archive")
		XCTAssertEqual(sparse.violations, [])
	}

	/// Nothing may walk the 932 scattered local headers. Against the real file that would simply
	/// work; here it is a failure, which is the point of the sparse fixture.
	func test_openingDoesNotResolveEveryLocalHeader() throws {
		let bytes = try ADAFFixtures.sparseBytes("OD_ringfort")
		_ = try PyTorchZipArchive.open(bytes)
		XCTAssertEqual(bytes.violations, [], "opening must read only the end records and the directory")
	}

	// MARK: - ZIP64: present is normal, needed is refused

	/// The rule that would have rejected every ADAF model if it had been derived from the spec: torch
	/// writes the ZIP64 record and locator unconditionally, at 518 MB, with all 32-bit fields valid.
	func test_anArchiveCarryingAnAgreeingZip64Chain_isAccepted() throws {
		let bytes = TestZipBuilder.torchLike().build()
		let archive = try PyTorchZipArchive.open(ArrayBytes(bytes))
		XCTAssertEqual(archive.entries.count, 2)
	}

	func test_anArchiveWithoutAZip64Chain_isAlsoAccepted() throws {
		var builder = TestZipBuilder.torchLike()
		builder.includeZip64Chain = false
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertEqual(archive.entries.count, 2)
	}

	func test_aZip64RecordDisagreeingWithTheClassicOne_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.overrideZip64EntryCount = 3
		assertThrows(builder) { error in
			guard case .zip64ChainInconsistent = error else { return XCTFail("got \(error)") }
		}
	}

	func test_aSentinelEntryCount_isRefusedAsNeedingZip64() throws {
		var builder = TestZipBuilder.torchLike()
		builder.overrideEntryCount = 0xFFFF
		assertThrows(builder) { error in
			guard case .zip64Required = error else { return XCTFail("got \(error)") }
		}
	}

	func test_aPerEntryZip64ExtraField_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		// Header ID 0x0001 with an 8-byte body: a legal ZIP64 extra field.
		builder.entries[0].centralExtra = [0x01, 0x00, 0x08, 0x00] + [UInt8](repeating: 0, count: 8)
		assertThrows(builder) { error in
			guard case .zip64Required = error else { return XCTFail("got \(error)") }
		}
	}

	// MARK: - Where the end record must be

	/// Refusing a commented archive is deliberate; saying *which* refusal it was is the part that
	/// matters, since "not a zip file" would be actively misleading about a perfectly good zip.
	func test_anArchiveWithATrailingComment_isRefusedWithItsOwnError() throws {
		var builder = TestZipBuilder.torchLike()
		builder.comment = Array("hello".utf8)
		assertThrows(builder) { XCTAssertEqual($0, .zipCommentUnsupported(byteCount: 5)) }
	}

	func test_bytesAppendedAfterTheEndRecord_areRefused() throws {
		let bytes = TestZipBuilder.torchLike().build() + [0x00, 0x00]
		assertThrows(bytes) { XCTAssertEqual($0, .unexpectedTrailingBytes) }
	}

	func test_bytesThatAreNotAnArchiveAtAll_saySo() throws {
		assertThrows([UInt8](repeating: 0x2A, count: 4096)) { XCTAssertEqual($0, .notAZipArchive) }
	}

	/// Two complete archives concatenated — the zip-prefix confusion shape that APK and JAR signing
	/// have been bitten by. The trailing archive's end record sits at `fileSize - 22` and all of its
	/// internal arithmetic is self-consistent, but every offset it records is relative to its own
	/// start, so they point into the *decoy*. Only exact adjacency between the directory, the ZIP64
	/// chain and the end of the file refuses this; any inequality accepts the decoy's contents.
	func test_aValidArchiveAppendedToAnotherOne_isRefused() throws {
		let decoy = TestZipBuilder.torchLike(root: "decoy.pth").build()
		let real = TestZipBuilder.torchLike(root: "real.pth").build()
		assertThrows(decoy + real) { error in
			switch error {
			case .malformedCentralDirectory, .zip64ChainInconsistent: break
			default: XCTFail("got \(error)")
			}
		}
	}

	/// The check that ties the recorded directory location to the tail structures.
	///
	/// Here everything is individually valid — the directory parses, the ZIP64 record and locator are
	/// correctly chained to the end record, the end record is at `fileSize - 22` — and only
	/// `zip64RecordOffset == cdOffset + cdSize` notices that the directory the archive *points at*
	/// need not be the one the tail was built around. Without it, an archive can relocate the reader
	/// onto a second directory elsewhere in the same file.
	func test_aZip64RecordNotAdjacentToTheDirectory_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.gapBeforeZip64Chain = 64
		assertThrows(builder) { error in
			guard case .zip64ChainInconsistent = error else { return XCTFail("got \(error)") }
		}
	}

	/// The same gap, in an archive that carries no ZIP64 chain at all: then it is the plain
	/// directory-to-end-record adjacency that has to notice.
	func test_aGapBetweenTheDirectoryAndTheEndRecord_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.includeZip64Chain = false
		builder.gapBeforeZip64Chain = 64
		assertThrows(builder) { error in
			guard case .malformedCentralDirectory = error else { return XCTFail("got \(error)") }
		}
	}

	func test_aTruncatedArchive_isRefused() throws {
		let bytes = TestZipBuilder.torchLike().build()
		assertThrows(Array(bytes.dropLast(4))) { XCTAssertEqual($0, .notAZipArchive) }
	}

	func test_anEmptySource_isRefused() throws {
		assertThrows([UInt8]()) { XCTAssertEqual($0, .notAZipArchive) }
	}

	// MARK: - Entry-level refusals

	func test_aDeflatedEntry_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].method = 8
		assertThrows(builder) { XCTAssertEqual($0, .unsupportedCompression(method: 8)) }
	}

	func test_anEncryptedEntry_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].flags = 0x0809
		assertThrows(builder) { XCTAssertEqual($0, .unsupportedEntryFlags(0x0809)) }
	}

	func test_duplicateEntryNames_areRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries.append(.init(name: "checkpoint.pth/data.pkl", payload: [0x2E]))
		assertThrows(builder) { error in
			guard case .duplicateEntryName = error else { return XCTFail("got \(error)") }
		}
	}

	func test_aDirectorySizeThatDoesNotMatchTheRecords_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.overrideDirectorySize = 10
		assertThrows(builder) { error in
			switch error {
			case .malformedCentralDirectory, .zip64ChainInconsistent: break
			default: XCTFail("got \(error)")
			}
		}
	}

	// MARK: - Reading an entry

	/// The check that binds a payload to the record that pointed at it.
	func test_aChecksumThatDoesNotMatchThePayload_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].overrideCRC = 0xDEAD_BEEF
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		let (_, pickle) = try archive.torchPickleEntry()
		XCTAssertThrowsError(try archive.bytes(of: pickle, maximumByteCount: 1024)) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .checksumMismatch(name: "checkpoint.pth/data.pkl"))
		}
	}

	/// A central record naming `…/data.pkl` while its local header names something else is how an
	/// archive gets a reader to parse the wrong payload.
	func test_aLocalHeaderNamingSomethingElse_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].overrideLocalName = "checkpoint.pth/other.pkl"
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		let (_, pickle) = try archive.torchPickleEntry()
		XCTAssertThrowsError(try archive.bytes(of: pickle, maximumByteCount: 1024)) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .localHeaderMismatch(name: "checkpoint.pth/data.pkl"))
		}
	}

	/// The local extra length legitimately differs from the central one — 56 against 0 on a real
	/// `data.pkl`. Comparing them looks like tidying an inconsistency and rejects every real file.
	func test_aLocalExtraLengthDifferingFromTheCentralOne_isFine() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].localExtraLength = 56
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		let (_, pickle) = try archive.torchPickleEntry()
		XCTAssertEqual(try archive.bytes(of: pickle, maximumByteCount: 1024), [0x80, 0x02, 0x2E])
	}

	func test_anEntryLargerThanTheCallersBudget_isRefusedBeforeTheRead() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(TestZipBuilder.torchLike().build()))
		let (_, pickle) = try archive.torchPickleEntry()
		XCTAssertThrowsError(try archive.bytes(of: pickle, maximumByteCount: 2)) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .entryTooLarge(name: "checkpoint.pth/data.pkl", byteCount: 3))
		}
	}

	func test_aCentralSizeReachingPastTheEndOfTheFile_isRefused() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries[0].overrideCentralSize = 1_000_000
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		let (_, pickle) = try archive.torchPickleEntry()
		XCTAssertThrowsError(try archive.bytes(of: pickle, maximumByteCount: 8 * 1024 * 1024)) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .entryOutOfBounds(name: "checkpoint.pth/data.pkl"))
		}
	}

	// MARK: - The torch root

	func test_twoPickleCandidates_areAmbiguousRatherThanFirstWins() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries.append(.init(name: "data.pkl", payload: [0x2E]))
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertThrowsError(try archive.torchPickleEntry()) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .ambiguousPickleEntry(count: 2))
		}
	}

	func test_anArchiveWithNoPickle_saysSo() throws {
		var builder = TestZipBuilder.torchLike()
		builder.entries.removeFirst()
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertThrowsError(try archive.torchPickleEntry()) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .pickleEntryNotFound)
		}
	}

	func test_aMultiComponentRoot_isRefused() throws {
		let builder = TestZipBuilder.torchLike(root: "a/b")
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertThrowsError(try archive.torchPickleEntry()) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .unsupportedRoot("a/b"))
		}
	}

	func test_aTraversalRoot_isRefused() throws {
		let builder = TestZipBuilder.torchLike(root: "..")
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertThrowsError(try archive.torchPickleEntry()) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .unsupportedRoot(".."))
		}
	}

	func test_aBareDataPickleWithNoRoot_isRefused() throws {
		let builder = TestZipBuilder(entries: [.init(name: "data.pkl", payload: [0x2E])])
		let archive = try PyTorchZipArchive.open(ArrayBytes(builder.build()))
		XCTAssertThrowsError(try archive.torchPickleEntry()) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .unsupportedRoot(""))
		}
	}

	// MARK: - Helpers

	private func assertThrows(
		_ builder: TestZipBuilder,
		file: StaticString = #filePath,
		line: UInt = #line,
		_ check: (PyTorchZipArchiveError) -> Void
	) {
		assertThrows(builder.build(), file: file, line: line, check)
	}

	private func assertThrows(
		_ bytes: [UInt8],
		file: StaticString = #filePath,
		line: UInt = #line,
		_ check: (PyTorchZipArchiveError) -> Void
	) {
		XCTAssertThrowsError(try PyTorchZipArchive.open(ArrayBytes(bytes)), file: file, line: line) { error in
			guard let error = error as? PyTorchZipArchiveError else {
				return XCTFail("unexpected error type: \(error)", file: file, line: line)
			}
			check(error)
		}
	}
}
