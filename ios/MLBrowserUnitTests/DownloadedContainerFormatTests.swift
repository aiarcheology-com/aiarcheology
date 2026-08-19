//
//  DownloadedContainerFormatTests.swift
//  MLBrowserUnitTests
//
//  AIA-0654.
//

import XCTest
@testable import ML_Browser

/// The sniffer's contract has two halves, and the second is the one that protects shipped
/// behaviour: it must recognise the containers the app cannot import, and it must answer
/// `.unrecognized` for *everything else* — including malformed, hostile and unreadable input —
/// because `.unrecognized` is what routes a file down the path it took before AIA-0654.
final class DownloadedContainerFormatTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("DownloadedContainerFormatTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let directory {
			try? FileManager.default.removeItem(at: directory)
		}
		directory = nil
		try super.tearDownWithError()
	}

	// MARK: - PyTorch zip checkpoints

	func test_zipWhoseFirstEntryIsTheTorchPickle_isACheckpoint() throws {
		let url = try write(zip(entries: [("archive/data.pkl", 16)]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .pyTorchZipCheckpoint)
	}

	/// Entry order is a property of the writer, not of the zip format, so a few leading records
	/// must not hide the pickle.
	func test_zipWithTheTorchPickleBehindLeadingEntries_isACheckpoint() throws {
		let url = try write(zip(entries: [
			("archive/byteorder", 6),
			("archive/version", 2),
			("archive/data.pkl", 32)
		]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .pyTorchZipCheckpoint)
	}

	/// `torch.save` pads local headers with an alignment extra field, so a leading entry in a real
	/// checkpoint carries a nonzero extra length. Without this the `extraLength` term of the walk's
	/// advance is never exercised, and a bug there would pass the whole suite while silently missing
	/// every real ADAF file — safe in direction, but the feature would simply never fire.
	func test_zipWithExtraFieldsOnLeadingEntries_isACheckpoint() throws {
		let url = try write(zip(entries: [
			("archive/byteorder", 6, 12),
			("archive/version", 2, 4),
			("archive/data.pkl", 32, 8)
		]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .pyTorchZipCheckpoint)
	}

	/// A bare `data.pkl` with no root directory still counts.
	func test_zipWithAnUnrootedTorchPickle_isACheckpoint() throws {
		let url = try write(zip(entries: [("data.pkl", 8)]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .pyTorchZipCheckpoint)
	}

	/// An ordinary zip is not a checkpoint, and must keep taking today's path.
	func test_zipWithoutATorchPickle_isUnrecognized() throws {
		let url = try write(zip(entries: [("model/weights.bin", 24), ("model/config.json", 12)]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	/// A name that merely *ends* in the pickle's name is not the pickle.
	func test_zipEntryEndingInTheNameWithoutASeparator_isUnrecognized() throws {
		let url = try write(zip(entries: [("archive/notdata.pkl", 8)]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	/// General-purpose bit 3 means the sizes live in a trailing descriptor, so the next header's
	/// offset cannot be derived from this one. The walk must stop rather than jump to a computed
	/// garbage offset.
	func test_zipWithAStreamedLeadingEntry_stopsAndIsUnrecognized() throws {
		var bytes = zip(entries: [("archive/streamed", 4), ("archive/data.pkl", 8)])
		bytes[6] |= 0x08
		let url = try write(bytes)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	/// The walk is bounded, so a pickle buried behind more records than it inspects is a declared
	/// false negative — it falls through to today's behaviour rather than to a wrong action.
	func test_zipWithTheTorchPickleBeyondTheInspectionBound_isUnrecognized() throws {
		var entries = (0..<9).map { ("archive/filler\($0)", 4) }
		entries.append(("archive/data.pkl", 8))
		let url = try write(zip(entries: entries))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	/// A header that claims a name running past the end of the file must not read past the prefix.
	func test_zipHeaderTruncatedMidName_isUnrecognized() throws {
		var bytes = zip(entries: [("archive/data.pkl", 8)])
		bytes = Array(bytes.prefix(34))
		let url = try write(bytes)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_zipHeaderClaimingAnAbsurdNameLength_isUnrecognized() throws {
		var bytes = zip(entries: [("archive/data.pkl", 8)])
		bytes[26] = 0xFF
		bytes[27] = 0xFF
		let url = try write(bytes)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	// MARK: - tar

	func test_posixTarHeader_isATarArchive() throws {
		let url = try write(tarHeader(magic: Array("ustar\0".utf8) + [0x30, 0x30]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .tarArchive)
	}

	func test_gnuTarHeader_isATarArchive() throws {
		let url = try write(tarHeader(magic: Array("ustar  ".utf8) + [0x00]))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .tarArchive)
	}

	/// The magic alone is five bytes that can occur in any file; without a well-formed octal size
	/// beside it, this is not a tar and must keep taking today's path.
	func test_bytesContainingTheTarMagicWithoutAValidSizeField_isUnrecognized() throws {
		var bytes = tarHeader(magic: Array("ustar\0".utf8) + [0x30, 0x30])
		for index in 124..<136 { bytes[index] = UInt8(ascii: "Z") }
		let url = try write(bytes)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_tarMagicAtTheWrongOffset_isUnrecognized() throws {
		var bytes = [UInt8](repeating: 0, count: 512)
		let magic = Array("ustar\0".utf8)
		bytes.replaceSubrange(100..<(100 + magic.count), with: magic)
		let url = try write(bytes)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	// MARK: - Everything the app imports normally

	/// A Core ML model is a protobuf; it must never be mistaken for a container.
	func test_protobufLikePrefix_isUnrecognized() throws {
		let url = try write([0x08, 0x01, 0x12, 0x07] + [UInt8](repeating: 0x2A, count: 600))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	/// Size is not a signal, and must never become one: a large unrecognized file is still
	/// unrecognized. This is the lock on "no import that works today changes path".
	func test_largeUnrecognizedFile_isStillUnrecognized() throws {
		let url = try write([UInt8](repeating: 0x5A, count: 3_000_000))
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	// MARK: - Totality

	/// A resumed `.aiagraph` conversion hands the import path a **directory**. The sniffer is on
	/// that path, so answering rather than throwing is what keeps that flow working.
	func test_directory_isUnrecognized() throws {
		let url = directory.appendingPathComponent("package.aiagraph", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_missingFile_isUnrecognized() {
		let url = directory.appendingPathComponent("nothing-here.bin")
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_unreadableFile_isUnrecognized() throws {
		let url = try write(zip(entries: [("archive/data.pkl", 16)]))
		try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
		// Guard against the test silently proving nothing: root can read a 000 file.
		try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "File is readable; permissions did not take effect.")
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_emptyFile_isUnrecognized() throws {
		let url = try write([])
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	func test_fileShorterThanAnyHeader_isUnrecognized() throws {
		let url = try write([0x50, 0x4B, 0x03])
		XCTAssertEqual(DownloadedContainerFormat.classify(fileAt: url), .unrecognized)
	}

	// MARK: - Fixtures

	private func write(_ bytes: [UInt8], named name: String = "download.tmp") throws -> URL {
		let url = directory.appendingPathComponent(name)
		try Data(bytes).write(to: url)
		return url
	}

	/// A minimal zip of stored entries: local header + name + extra + payload, repeated. Enough of
	/// the format for a prefix sniff, which never reads the central directory.
	private func zip(entries: [(String, Int)]) -> [UInt8] {
		zip(entries: entries.map { ($0.0, $0.1, 0) })
	}

	private func zip(entries: [(String, Int, Int)]) -> [UInt8] {
		var bytes: [UInt8] = []
		for (name, payloadSize, extraSize) in entries {
			let nameBytes = [UInt8](name.utf8)
			bytes += [0x50, 0x4B, 0x03, 0x04]      // signature
			bytes += [0x14, 0x00]                  // version needed
			bytes += [0x00, 0x00]                  // general-purpose flags
			bytes += [0x00, 0x00]                  // method: stored
			bytes += [0x00, 0x00, 0x00, 0x00]      // time + date
			bytes += [0x00, 0x00, 0x00, 0x00]      // crc32
			bytes += uint32(payloadSize)           // compressed size
			bytes += uint32(payloadSize)           // uncompressed size
			bytes += uint16(nameBytes.count)
			bytes += uint16(extraSize)             // extra length (torch pads for alignment)
			bytes += nameBytes
			bytes += [UInt8](repeating: 0xFF, count: extraSize)
			bytes += [UInt8](repeating: 0x00, count: payloadSize)
		}
		return bytes
	}

	private func tarHeader(magic: [UInt8]) -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: 512)
		let name = [UInt8]("weights.bin".utf8)
		bytes.replaceSubrange(0..<name.count, with: name)
		let size = [UInt8]("00000000144\0".utf8)                 // octal, NUL-terminated
		bytes.replaceSubrange(124..<(124 + size.count), with: size)
		bytes.replaceSubrange(257..<(257 + magic.count), with: magic)
		return bytes
	}

	private func uint16(_ value: Int) -> [UInt8] {
		[UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
	}

	private func uint32(_ value: Int) -> [UInt8] {
		[
			UInt8(value & 0xFF),
			UInt8((value >> 8) & 0xFF),
			UInt8((value >> 16) & 0xFF),
			UInt8((value >> 24) & 0xFF)
		]
	}
}
