//
//  RandomAccessBytes.swift
//  NativeModelConverter
//
//  Bounded random access to a byte source, so what a reader reads is a checkable fact (AIA-0666).
//

import Foundation

/// A source of bytes a reader can seek within, of a length known up front.
///
/// The PyTorch checkpoint reader exists to answer questions about a 518 MB file while reading a few
/// hundred kilobytes of it, and "reads only what it needs" is worth nothing as a comment. Routing
/// every read through one narrow protocol makes it measurable: a test can wrap any source in a
/// decorator that counts bytes, or in one that fails the test when a read lands outside the region
/// it expected. Both are how the read set stops being a promise.
///
/// It is also what lets the same code run against a real file, an in-memory array, and a fixture
/// that holds only the two regions of a real archive that the reader is supposed to touch.
///
/// - Note: deliberately not `Sendable`. A file-backed source owns a file handle and a cursor; the
///   reader runs inside one task and has no reason to share one across isolation domains.
protocol RandomAccessBytes {
	/// The length of the source. For a file this is its size; for a partial fixture it is the size
	/// the *original* had, which is what makes bounds checks against it meaningful.
	var totalLength: Int { get }

	/// Reads exactly `count` bytes at `offset`.
	///
	/// - Throws: ``RandomAccessBytesError/outOfBounds(offset:count:totalLength:)`` when the range is
	///   not wholly inside the source, and ``RandomAccessBytesError/shortRead(offset:expected:got:)``
	///   when the source returns fewer bytes than a bounds-checked range promised. A short read is
	///   never silently padded: it means the source disagrees with its own declared length, which a
	///   parser must not paper over.
	func read(at offset: Int, count: Int) throws -> [UInt8]
}

enum RandomAccessBytesError: Error, Equatable {
	case outOfBounds(offset: Int, count: Int, totalLength: Int)
	case shortRead(offset: Int, expected: Int, got: Int)
	case unreadable(String)
}

extension RandomAccessBytes {
	/// Whether `offset ..< offset + count` lies wholly inside the source.
	///
	/// Written with a subtraction rather than `offset + count <= totalLength` because a hostile size
	/// read out of a file can be large enough that the addition overflows, and an overflowed
	/// comparison passes. Negative values are rejected first so the subtraction cannot underflow.
	func containsRange(offset: Int, count: Int) -> Bool {
		guard offset >= 0, count >= 0, offset <= totalLength else { return false }
		return count <= totalLength - offset
	}

	/// Reads `count` bytes at `offset`, or throws if the range is not wholly inside the source.
	func readChecked(at offset: Int, count: Int) throws -> [UInt8] {
		guard containsRange(offset: offset, count: count) else {
			throw RandomAccessBytesError.outOfBounds(offset: offset, count: count, totalLength: totalLength)
		}
		return try read(at: offset, count: count)
	}
}

/// A byte source backed by an array already in memory.
struct ArrayBytes: RandomAccessBytes {
	private let bytes: [UInt8]

	init(_ bytes: [UInt8]) {
		self.bytes = bytes
	}

	var totalLength: Int { bytes.count }

	func read(at offset: Int, count: Int) throws -> [UInt8] {
		guard containsRange(offset: offset, count: count) else {
			throw RandomAccessBytesError.outOfBounds(offset: offset, count: count, totalLength: totalLength)
		}
		return Array(bytes[offset..<(offset + count)])
	}
}

/// A byte source backed by a file, read through a handle rather than loaded.
///
/// Nothing here maps or copies the file: the checkpoint reader's whole point is that a half-gigabyte
/// archive costs a few hundred kilobytes of reads, and materialising it would defeat that before the
/// first byte is parsed.
final class FileBytes: RandomAccessBytes {
	private let handle: FileHandle
	let totalLength: Int

	/// - Throws: ``RandomAccessBytesError/unreadable(_:)`` for anything that is not a readable file,
	///   including a directory — the import path hands the reader whatever the user chose, and a
	///   resumed `.aiagraph` conversion really does present a directory.
	init(url: URL) throws {
		guard let handle = try? FileHandle(forReadingFrom: url) else {
			throw RandomAccessBytesError.unreadable(url.lastPathComponent)
		}
		let size = (try? handle.seekToEnd()).flatMap { Int(exactly: $0) }
		guard let size else {
			try? handle.close()
			throw RandomAccessBytesError.unreadable(url.lastPathComponent)
		}
		self.handle = handle
		self.totalLength = size
	}

	deinit {
		try? handle.close()
	}

	func read(at offset: Int, count: Int) throws -> [UInt8] {
		guard containsRange(offset: offset, count: count) else {
			throw RandomAccessBytesError.outOfBounds(offset: offset, count: count, totalLength: totalLength)
		}
		guard count > 0 else { return [] }
		do {
			try handle.seek(toOffset: UInt64(offset))
		} catch {
			throw RandomAccessBytesError.unreadable("seek to \(offset)")
		}
		guard let data = try? handle.read(upToCount: count) else {
			throw RandomAccessBytesError.unreadable("read \(count) at \(offset)")
		}
		guard data.count == count else {
			throw RandomAccessBytesError.shortRead(offset: offset, expected: count, got: data.count)
		}
		return [UInt8](data)
	}
}
