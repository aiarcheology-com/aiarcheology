//
//  FindingsArchiveReadingTests.swift
//  NativeModelConverterTests
//
//  AIA-713: reading the findings-export archive with the shared zip reader.
//

import XCTest
@testable import NativeModelConverter

/// Reading the archive `FindingExporter` writes, as opposed to the one `torch.save` writes.
///
/// Deliberately its own suite rather than more cases in `PyTorchZipArchiveTests`: these assert a
/// DIFFERENT producer's output through the same reader, and every one of them runs against a
/// committed real archive — bytes `NSFileCoordinator(.forUploading)` actually emitted — never
/// against the synthetic `TestZipBuilder`. That builder is documented as being for refusals only,
/// because an archive hand-built from the reader's own beliefs agrees with the reader whether or
/// not either matches a real file; AIA-0654 shipped a sniffer that way and it could not read the
/// files it existed for.
final class FindingsArchiveReadingTests: XCTestCase {

	/// Real bytes, not the builder: this fixture is what `NSFileCoordinator(.forUploading)` actually
	/// produced for a findings export, deflate and all. A hand-built archive would only prove the
	/// reader agrees with the test's beliefs — the mistake AIA-0654 shipped.
	private func findingsArchiveBytes() throws -> [UInt8] {
		let url = try XCTUnwrap(Bundle.module.url(
			forResource: "findings-export-deflate",
			withExtension: "zip"
		), "the findings deflate fixture is missing from the test bundle")
		return [UInt8](try Data(contentsOf: url))
	}

	/// The whole reason deflate exists in this reader: every entry the app's own exporter writes is
	/// deflated, INCLUDING the already-compressed image — measured, not assumed.
	func test_findingsArchive_opensWithDeflateAndEveryEntryIsDeflated() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(try findingsArchiveBytes()), allowsDeflate: true)

		XCTAssertEqual(archive.entries.count, 3)
		XCTAssertEqual(
			Set(archive.entries.map(\.name)),
			[
				"Findings/findings.json",
				"Findings/findings.csv",
				"Findings/images/00000000-0000-0000-0000-000000000001.jpg"
			],
			"the zip's root entry is the Findings DIRECTORY, so nothing sits at the archive root"
		)
		XCTAssertTrue(archive.entries.allSatisfy { $0.method == 8 }, "NSFileCoordinator deflates everything")
	}

	/// Inflation actually reconstructs the bytes, and the CRC in the central directory confirms it.
	func test_findingsArchive_inflatesAnEntryBackToItsOriginalBytes() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(try findingsArchiveBytes()), allowsDeflate: true)
		let entry = try XCTUnwrap(archive.entry(named: "Findings/findings.json"))

		XCTAssertLessThan(entry.compressedSize, entry.uncompressedSize, "this entry really is compressed")

		let payload = try archive.bytes(of: entry, maximumByteCount: 1024 * 1024)
		XCTAssertEqual(payload.count, entry.uncompressedSize)
		let text = try XCTUnwrap(String(bytes: payload, encoding: .utf8))
		XCTAssertEqual(
			text,
			#"{"schemaVersion":1,"findings":[{"id":"00000000-0000-0000-0000-000000000001","title":"Ringfort"}]}"#
		)
	}

	/// An image entry inflates byte-for-byte — the property archive import depends on, since it
	/// stores those bytes verbatim rather than re-encoding them through UIImage.
	func test_findingsArchive_inflatesImageBytesExactly() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(try findingsArchiveBytes()), allowsDeflate: true)
		let entry = try XCTUnwrap(archive.entry(named: "Findings/images/00000000-0000-0000-0000-000000000001.jpg"))

		let payload = try archive.bytes(of: entry, maximumByteCount: 1024 * 1024)
		var expected: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
		for i in 0..<4096 { expected.append(UInt8((i * 7) % 251)) }
		XCTAssertEqual(payload, expected)
	}

	/// The opt-in is load-bearing, and this is the test that proves it: the SAME real archive that
	/// opens above is refused by the default reader. If `allowsDeflate` ever stopped gating anything,
	/// the checkpoint path would silently start accepting compressed entries and this would fail.
	func test_findingsArchive_isRefusedByTheDefaultStoredOnlyReader() throws {
		let bytes = try findingsArchiveBytes()
		XCTAssertThrowsError(try PyTorchZipArchive.open(ArrayBytes(bytes))) { error in
			XCTAssertEqual(error as? PyTorchZipArchiveError, .unsupportedCompression(method: 8))
		}
	}

	/// Streaming has no inflate path, so it must say so rather than hand out compressed bytes as
	/// though they were the entry's contents.
	func test_streamingADeflatedEntry_isRefusedRatherThanReadingCompressedBytes() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(try findingsArchiveBytes()), allowsDeflate: true)
		let entry = try XCTUnwrap(archive.entry(named: "Findings/findings.json"))

		XCTAssertThrowsError(
			try archive.streamBytes(of: entry, maximumByteCount: 1024 * 1024, chunkByteCount: 64) { _ in }
		) { error in
			XCTAssertEqual(
				error as? PyTorchZipArchiveError,
				.streamingUnsupportedForDeflatedEntry(name: "Findings/findings.json")
			)
		}
	}

	/// The zip-bomb defence is the declared size plus `maximumByteCount`, checked BEFORE any read or
	/// allocation — so a caller's cap is a hard ceiling on memory regardless of what deflate would
	/// have expanded to.
	func test_deflatedEntryOverTheCallersCap_isRefusedBeforeAnythingIsAllocated() throws {
		let archive = try PyTorchZipArchive.open(ArrayBytes(try findingsArchiveBytes()), allowsDeflate: true)
		let entry = try XCTUnwrap(archive.entry(named: "Findings/images/00000000-0000-0000-0000-000000000001.jpg"))

		XCTAssertThrowsError(try archive.bytes(of: entry, maximumByteCount: 64)) { error in
			XCTAssertEqual(
				error as? PyTorchZipArchiveError,
				.entryTooLarge(name: entry.name, byteCount: entry.uncompressedSize)
			)
		}
	}

	/// A deflated entry whose writer put REAL sizes in the local header and left the data-descriptor
	/// bit clear — Python `zipfile`, the `zip` CLI, and most server-side writers all do this.
	///
	/// The committed `NSFileCoordinator` fixture cannot cover it: that writer always sets the
	/// descriptor bit and zeroes the local sizes, so the comparison branch is never reached. Without
	/// this test, a reader that compared the local COMPRESSED size against `uncompressedSize` looked
	/// perfectly green while rejecting every archive from every other zip writer in existence.
	func test_deflatedEntryWithRealSizesInItsLocalHeader_isAccepted() throws {
		let url = try XCTUnwrap(Bundle.module.url(
			forResource: "findings-export-deflate-nodescriptor",
			withExtension: "zip"
		))
		let reader = try ZipArchiveReader(bytes: [UInt8](try Data(contentsOf: url)), allowsDeflate: true)

		let payload = try reader.bytes(named: "Findings/findings.json", maximumByteCount: 1024 * 1024)
		let text = try XCTUnwrap(String(bytes: payload, encoding: .utf8))
		XCTAssertTrue(text.hasPrefix(#"{"schemaVersion":1"#))
		XCTAssertEqual(payload.count, 990, "the entry must inflate to the size its directory declares")
	}

	// MARK: - The public façade the app actually calls

	func test_facade_readsTheFindingsArchiveAndInflatesAnEntry() throws {
		let reader = try ZipArchiveReader(bytes: try findingsArchiveBytes(), allowsDeflate: true)

		XCTAssertEqual(
			Set(reader.entries.map(\.name)),
			[
				"Findings/findings.json",
				"Findings/findings.csv",
				"Findings/images/00000000-0000-0000-0000-000000000001.jpg"
			]
		)
		let payload = try reader.bytes(named: "Findings/findings.json", maximumByteCount: 1024 * 1024)
		let text = try XCTUnwrap(String(bytes: payload, encoding: .utf8))
		XCTAssertTrue(text.hasPrefix(#"{"schemaVersion":1"#))
	}

	/// The façade must not quietly widen what the reader accepts: without opting in, a deflated
	/// archive is still refused.
	func test_facade_withoutOptingIntoDeflate_refusesTheArchive() throws {
		XCTAssertThrowsError(try ZipArchiveReader(bytes: try findingsArchiveBytes())) { error in
			guard case .unreadable = error as? ZipArchiveReaderError else {
				return XCTFail("expected .unreadable, got \(error)")
			}
		}
	}

	func test_facade_missingEntry_isNamedRatherThanGeneric() throws {
		let reader = try ZipArchiveReader(bytes: try findingsArchiveBytes(), allowsDeflate: true)
		XCTAssertThrowsError(try reader.bytes(named: "Findings/nope.json", maximumByteCount: 1024)) { error in
			XCTAssertEqual(error as? ZipArchiveReaderError, .entryNotFound(name: "Findings/nope.json"))
		}
	}

	/// The bomb bound, surfaced through the façade: refused on the DECLARED size, before allocation.
	func test_facade_entryOverTheCap_isRefusedOnItsDeclaredSize() throws {
		let reader = try ZipArchiveReader(bytes: try findingsArchiveBytes(), allowsDeflate: true)
		let name = "Findings/images/00000000-0000-0000-0000-000000000001.jpg"
		XCTAssertThrowsError(try reader.bytes(named: name, maximumByteCount: 64)) { error in
			XCTAssertEqual(error as? ZipArchiveReaderError, .entryTooLarge(name: name, byteCount: 4100))
		}
	}

	/// Bytes that are not an archive at all get the one error a user-facing message can be written
	/// from, rather than a structural complaint about central directories.
	func test_facade_nonArchiveBytes_saySoPlainly() {
		XCTAssertThrowsError(try ZipArchiveReader(bytes: Array("not a zip".utf8), allowsDeflate: true)) { error in
			XCTAssertEqual(error as? ZipArchiveReaderError, .notAZipArchive)
		}
	}
}
