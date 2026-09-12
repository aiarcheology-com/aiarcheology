//
//  ADAFCheckpointFixtures.swift
//  NativeModelConverterTests
//
//  Real ADAF checkpoint bytes, and the doubles that keep the reader honest about them (AIA-0666).
//

import CryptoKit
import XCTest
@testable import NativeModelConverter

/// The manifest describing which byte ranges of which published checkpoint are committed here.
///
/// See `Fixtures/ADAF/NOTICE.md` for the source and its CC-BY-SA-4.0 attribution.
struct ADAFFixtureManifest: Decodable {
	struct Region: Decodable {
		let offset: Int
		let length: Int
		let file: String
		let sha256: String
	}

	struct Model: Decodable {
		let id: String
		let fileName: String
		let url: String
		/// The length of the **original** published file, not of the committed excerpt. Bounds checks
		/// are meaningful only against this.
		let totalLength: Int
		let md5: String?
		/// What the catalog must answer for this file: `objectDetection` or `segmentation`.
		let expects: String?
		let classLabel: String?
		let tensorCount: Int?
		/// Present only for the models whose bytes are committed here. The rest are listed so the
		/// fetch script and the gated suite know what to get and how to verify it.
		let head: Region?
		let tail: Region?
	}

	let models: [Model]
}

/// A byte source that holds only the committed regions of a real archive but declares the real
/// file's full length.
///
/// This is the fixture that makes the checkpoint reader's read set a *test*, not a promise. The
/// reader is supposed to touch four things — the end-of-central-directory records, the central
/// directory, `data.pkl`, and `version` — and every one of them lies in the head or the tail. Any
/// read landing between them is a regression: something started walking the 932 scattered local
/// headers, and against the real file that would simply have worked, silently, until it was M3's
/// problem and a 518 MB one.
///
/// - Important: an out-of-region read **fails the test at the read site and then returns zeros**. It
///   deliberately does not throw. A throw would be caught by the reader, rendered as "this archive
///   is malformed", and a test asserting a refusal would pass — so the coverage hole and the correct
///   behaviour would produce the same green. Returning zeros also lets one run surface *every*
///   violation instead of stopping at the first.
final class SparseFixtureBytes: RandomAccessBytes {
	/// A read that landed outside every committed region.
	struct Violation: Equatable, CustomStringConvertible {
		let offset: Int
		let count: Int

		var description: String { "read(at: \(offset), count: \(count))" }
	}

	let totalLength: Int
	private let regions: [(range: Range<Int>, bytes: [UInt8])]
	private(set) var violations: [Violation] = []
	private(set) var bytesRead = 0

	init(totalLength: Int, regions: [(offset: Int, bytes: [UInt8])]) {
		self.totalLength = totalLength
		self.regions = regions.map { ($0.offset..<($0.offset + $0.bytes.count), $0.bytes) }
	}

	func read(at offset: Int, count: Int) throws -> [UInt8] {
		guard containsRange(offset: offset, count: count) else {
			// Out of bounds is a different thing from out of region, and must stay different: the
			// reader is expected to reject a central-directory entry claiming bytes past the end of
			// the file, and that expectation needs a real error behind it.
			throw RandomAccessBytesError.outOfBounds(offset: offset, count: count, totalLength: totalLength)
		}
		bytesRead += count
		guard count > 0 else { return [] }

		let wanted = offset..<(offset + count)
		// Wholly inside one region, or it is a violation. A read straddling a boundary is not served
		// half from real bytes and half from zeros — that is the lie in its worst form, because the
		// prefix looks right and the parser walks into the padding believing it.
		if let region = regions.first(where: { $0.range.lowerBound <= wanted.lowerBound && wanted.upperBound <= $0.range.upperBound }) {
			let start = wanted.lowerBound - region.range.lowerBound
			return Array(region.bytes[start..<(start + count)])
		}

		let violation = Violation(offset: offset, count: count)
		violations.append(violation)
		XCTFail("""
			Read outside the committed fixture regions: \(violation). The checkpoint reader's read \
			set is {EOCD records, central directory, data.pkl, version}; everything else lives in the \
			~517 MB this fixture does not carry. Against the real file this read would have silently \
			succeeded.
			""")
		return [UInt8](repeating: 0, count: count)
	}
}

/// Wraps another source and counts what was read, so a byte budget can be asserted rather than
/// described.
final class CountingBytes: RandomAccessBytes {
	private let base: any RandomAccessBytes
	private(set) var bytesRead = 0
	private(set) var readCount = 0

	init(_ base: any RandomAccessBytes) {
		self.base = base
	}

	var totalLength: Int { base.totalLength }

	func read(at offset: Int, count: Int) throws -> [UInt8] {
		let bytes = try base.read(at: offset, count: count)
		bytesRead += bytes.count
		readCount += 1
		return bytes
	}
}

enum ADAFFixtures {
	/// The committed manifest.
	static func manifest() throws -> ADAFFixtureManifest {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: "ADAFCheckpointFixtures", withExtension: "json"),
			"ADAFCheckpointFixtures.json is not in the test bundle — check Package.swift resources."
		)
		return try JSONDecoder().decode(ADAFFixtureManifest.self, from: Data(contentsOf: url))
	}

	static func model(_ id: String) throws -> ADAFFixtureManifest.Model {
		let manifest = try manifest()
		return try XCTUnwrap(manifest.models.first { $0.id == id }, "no fixture named '\(id)'")
	}

	/// A byte source over the committed regions of `id`, declaring the original file's full length.
	///
    /// Verifies each region's SHA-256 against the manifest first: a truncated or re-cut fixture must
	/// fail here, naming itself, rather than deep inside a parser.
	static func sparseBytes(_ id: String) throws -> SparseFixtureBytes {
		let model = try self.model(id)
		let headRegion = try XCTUnwrap(model.head, "'\(id)' has no committed bytes — it is fetch-only")
		let tailRegion = try XCTUnwrap(model.tail, "'\(id)' has no committed bytes — it is fetch-only")
		let head = try region(headRegion)
		let tail = try region(tailRegion)
		return SparseFixtureBytes(
			totalLength: model.totalLength,
			regions: [(headRegion.offset, head), (tailRegion.offset, tail)]
		)
	}

	private static func region(_ region: ADAFFixtureManifest.Region) throws -> [UInt8] {
		let name = (region.file as NSString).deletingPathExtension
		let ext = (region.file as NSString).pathExtension
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: ext),
			"\(region.file) is not in the test bundle — check Package.swift resources."
		)
		let bytes = [UInt8](try Data(contentsOf: url))
		XCTAssertEqual(bytes.count, region.length, "\(region.file) is not the length the manifest records")
		XCTAssertEqual(sha256Hex(bytes), region.sha256, "\(region.file) does not match its manifest digest")
		return bytes
	}

	/// The directory holding whole (or head+tail sparse) checkpoints, when the gated suite is enabled.
	static var gatedDirectory: URL? {
		ProcessInfo.processInfo.environment["ADAF_CHECKPOINT_DIRECTORY"].map {
			URL(fileURLWithPath: $0, isDirectory: true)
		}
	}
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
	SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}
