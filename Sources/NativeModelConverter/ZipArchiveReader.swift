//
//  ZipArchiveReader.swift
//  NativeModelConverter
//
//  The app-facing surface of this package's hardened zip reader (AIA-713).
//

import Foundation

/// Why reading a zip archive failed, in the terms a caller outside this package can act on.
///
/// Deliberately coarser than ``PyTorchZipArchiveError``: that enum names every structural refusal
/// so the checkpoint importer can explain itself, and most of those distinctions are noise to a
/// caller that only needs to tell "this is not a usable archive" from "this entry is too big".
/// The underlying description is carried in ``unreadable`` so nothing is lost from a log.
public enum ZipArchiveReaderError: Error, Equatable {
	/// The bytes are not a zip archive at all.
	case notAZipArchive
	/// The archive is a zip, but this reader refuses it — truncated, ZIP64, comment-bearing,
	/// duplicate-named, compressed with something other than deflate, and so on.
	case unreadable(String)
	/// The named entry is not in the archive.
	case entryNotFound(name: String)
	/// The entry's DECLARED uncompressed size exceeds the caller's cap. Refused before any read or
	/// allocation, which is what bounds a decompression bomb.
	case entryTooLarge(name: String, byteCount: Int)
	/// The entry's bytes do not match the checksum the archive recorded for them.
	case corruptEntry(name: String)
}

/// A read-only, hostile-input-hardened view of a zip archive.
///
/// This is a thin public façade over ``PyTorchZipArchive``, which does the actual work and keeps
/// every refusal it already implements: trailing bytes after the end record, archive comments,
/// ZIP64 chains that disagree with the classic record, duplicate entry names, non-UTF-8 names,
/// entries that overlap the central directory, local headers that contradict the central record,
/// and CRC mismatches.
///
/// The façade exists because that type is internal and named for the format it was written to read.
/// Exporting it wholesale would put a `PyTorch`-named parser and its `RandomAccessBytes` protocol
/// into the public API of every caller; this exposes the three operations an archive importer
/// actually needs instead.
///
/// - Important: **deflate must be asked for.** `torch.save` writes stored entries and the checkpoint
///   path relies on anything else being refused, so `allowsDeflate` defaults to false.
public struct ZipArchiveReader {
	/// One entry, reduced to what a caller outside this package can use.
	public struct Entry: Equatable, Sendable {
		public let name: String
		/// The size the central directory DECLARES. Check it against a budget before reading.
		public let uncompressedSize: Int

		public init(name: String, uncompressedSize: Int) {
			self.name = name
			self.uncompressedSize = uncompressedSize
		}
	}

	private let archive: PyTorchZipArchive

	/// Opens an archive held entirely in memory.
	///
	/// - Parameter allowsDeflate: pass true to accept deflated entries. Archives written by
	///   `NSFileCoordinator(.forUploading)` — which is how this app exports — deflate every entry,
	///   including already-compressed ones.
	public init(bytes: [UInt8], allowsDeflate: Bool = false) throws {
		do {
			archive = try PyTorchZipArchive.open(ArrayBytes(bytes), allowsDeflate: allowsDeflate)
		} catch let error as PyTorchZipArchiveError {
			throw Self.surface(error, name: nil)
		}
	}

	/// Every entry the central directory declares, in directory order.
	public var entries: [Entry] {
		archive.entries.map { Entry(name: $0.name, uncompressedSize: $0.uncompressedSize) }
	}

	/// Reads and, when necessary, inflates one entry.
	///
	/// - Parameter maximumByteCount: refused above this, before any read or allocation. This is the
	///   decompression-bomb bound: inflation targets a buffer of exactly the declared size, so a
	///   caller's cap is a hard ceiling on memory no matter what the payload claims to expand to.
	public func bytes(named name: String, maximumByteCount: Int) throws -> [UInt8] {
		guard let entry = archive.entry(named: name) else {
			throw ZipArchiveReaderError.entryNotFound(name: name)
		}
		do {
			return try archive.bytes(of: entry, maximumByteCount: maximumByteCount)
		} catch let error as PyTorchZipArchiveError {
			throw Self.surface(error, name: name)
		}
	}

	private static func surface(_ error: PyTorchZipArchiveError, name: String?) -> ZipArchiveReaderError {
		switch error {
		case .notAZipArchive:
			return .notAZipArchive
		case let .entryTooLarge(entryName, byteCount):
			return .entryTooLarge(name: entryName, byteCount: byteCount)
		case let .checksumMismatch(entryName):
			return .corruptEntry(name: entryName)
		case let .inflationFailed(entryName):
			return .corruptEntry(name: entryName)
		default:
			// Everything else is a structural refusal the caller cannot act on differently. The
			// specific case still reaches the logs through the description.
			return .unreadable("\(error)\(name.map { " while reading '\($0)'" } ?? "")")
		}
	}
}
