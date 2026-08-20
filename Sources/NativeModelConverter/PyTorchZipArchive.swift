//
//  PyTorchZipArchive.swift
//  NativeModelConverter
//
//  Reading the zip container a `torch.save` checkpoint ships in (AIA-0666).
//

import Foundation

/// One entry in the central directory.
///
/// `uncompressedSize` comes from the central directory and nowhere else: every local header in a
/// real `torch.save` archive sets the data-descriptor flag and carries `csize = usize = 0`, so a
/// reader that sizes entries from local headers finds nothing at all. That mistake shipped once
/// already, in AIA-0654's container sniffer.
struct PyTorchZipEntry: Equatable {
	let name: String
	let uncompressedSize: Int
	let crc32: UInt32
	let localHeaderOffset: Int
	/// The central record's general-purpose flags and compression method, kept so the local header
	/// can be required to agree with them rather than merely to exist.
	let flags: UInt16
	let method: UInt16
}

enum PyTorchZipArchiveError: Error, Equatable {
	case notAZipArchive
	/// There is a plausible end-of-central-directory record, but it does not end at the end of the
	/// file — something has been appended, or the record is not the one it claims to be.
	case unexpectedTrailingBytes
	/// A well-formed archive that carries a trailing comment. Refused so the end record's position is
	/// a structural fact rather than something to search for; named separately so the message can say
	/// which of the two it was.
	case zipCommentUnsupported(byteCount: Int)
	/// The archive genuinely needs ZIP64 (a count or offset that does not fit 32 bits).
	case zip64Required(String)
	/// ZIP64 structures are present but do not agree with the classic record, or do not sit where
	/// the format requires. A disagreement means this reader would see a different archive than
	/// `unzip` does, which is worse than refusing.
	case zip64ChainInconsistent(String)
	case malformedCentralDirectory(String)
	case unsupportedCompression(method: Int)
	case unsupportedEntryFlags(UInt16)
	case duplicateEntryName(String)
	case entryNameNotUTF8
	case entryNameTooLong(Int)
	case tooManyEntries(Int)
	case centralDirectoryTooLarge(Int)
	case entryOutOfBounds(name: String)
	/// A local header disagrees with the central record that pointed at it.
	case localHeaderMismatch(name: String)
	case entryTooLarge(name: String, byteCount: Int)
	case checksumMismatch(name: String)
	case pickleEntryNotFound
	case ambiguousPickleEntry(count: Int)
	case unsupportedRoot(String)
}

/// A read-only view of a stored-entry zip archive, opened from its central directory.
///
/// Scope is deliberately narrow: this reads the archives `torch.save` writes, and refuses everything
/// else rather than growing toward a general zip reader. Every refusal is a distinct error so the
/// caller can say *why*, which is the whole point of the milestone this belongs to.
struct PyTorchZipArchive {
	let entries: [PyTorchZipEntry]
	private let source: any RandomAccessBytes
	private let index: [String: Int]
	/// Where the central directory starts. Entry payloads must end at or before it: a local header
	/// and payload placed *inside* the directory would otherwise be readable, which is a way to make
	/// one region of the file mean two things.
	private let directoryOffset: Int

	// MARK: - Format constants

	private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
	private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
	private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
	private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
	private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

	private static let endOfCentralDirectoryLength = 22
	private static let zip64LocatorLength = 20
	private static let zip64EndOfCentralDirectoryLength = 56
	private static let centralFileHeaderLength = 46
	private static let localFileHeaderLength = 30

	/// Flags a stored `torch.save` entry legitimately sets: bit 3 (sizes in a trailing data
	/// descriptor) and bit 11 (the name is UTF-8). Every other bit — encryption, strong encryption,
	/// patched data, masked local headers — is refused rather than ignored, because each one changes
	/// what the bytes at the data offset mean.
	private static let dataDescriptorFlag: UInt16 = 0x0008
	private static let permittedFlags: UInt16 = dataDescriptorFlag | 0x0800

	/// The ZIP64 extra field's header ID. Its presence means a size or offset in this record is a
	/// sentinel, so the 32-bit value read here would be `0xFFFFFFFF` used as a literal.
	private static let zip64ExtraHeaderID: UInt16 = 0x0001

	private static let maximumEntryCount = 200_000
	private static let maximumEntryNameLength = 1024
	private static let maximumCentralDirectoryLength = 32 * 1024 * 1024

	// MARK: - Opening

	/// Opens `source` by reading its end-of-central-directory records and central directory.
	///
	/// Nothing here walks local headers. Their offsets are recorded and resolved only when an entry's
	/// bytes are actually read, which for a checkpoint means `data.pkl` and `version` and nothing
	/// else — two reads instead of 934, and the reason a half-gigabyte archive costs a few hundred
	/// kilobytes.
	static func open(_ source: any RandomAccessBytes) throws -> PyTorchZipArchive {
		let directory = try readEndOfCentralDirectory(source)
		let entries = try readCentralDirectory(source, directory)
		var index: [String: Int] = [:]
		index.reserveCapacity(entries.count)
		for (position, entry) in entries.enumerated() {
			// Byte-exact, no case folding and no Unicode normalisation: two entries whose names
			// differ only in encoding are an attempt to make the lookup ambiguous, not a convenience.
			guard index.updateValue(position, forKey: entry.name) == nil else {
				throw PyTorchZipArchiveError.duplicateEntryName(entry.name)
			}
		}
		return PyTorchZipArchive(
			entries: entries, source: source, index: index, directoryOffset: directory.offset
		)
	}

	private struct Directory {
		let entryCount: Int
		let size: Int
		let offset: Int
	}

	/// Locates and validates both end-of-central-directory records.
	///
	/// **The classic record must sit at exactly `fileSize - 22` with no comment.** There is no
	/// backward scan for its signature. A scan has to choose a window size, and worse, `PK\u{05}\u{06}`
	/// occurs by chance inside central-directory data — CRCs and offsets look like random bytes — so
	/// a scan can select a record that was never a record. Requiring the exact position deletes that
	/// whole family instead of bounding it. It refuses a legitimately commented archive, which is the
	/// same trade already made for deflated entries and protocol-4 pickles, and it gets its own error
	/// so the refusal says why.
	private static func readEndOfCentralDirectory(_ source: any RandomAccessBytes) throws -> Directory {
		guard source.totalLength >= endOfCentralDirectoryLength else {
			throw PyTorchZipArchiveError.notAZipArchive
		}
		let eocdOffset = source.totalLength - endOfCentralDirectoryLength
		let eocd = try source.readChecked(at: eocdOffset, count: endOfCentralDirectoryLength)
		guard readUInt32(eocd, 0) == endOfCentralDirectorySignature else {
			throw try diagnoseMissingEndRecord(source)
		}
		// A record sitting at `fileSize - 22` that also claims a comment is describing bytes that are
		// not there, so it is not the record it purports to be.
		guard readUInt16(eocd, 20) == 0 else {
			throw PyTorchZipArchiveError.unexpectedTrailingBytes
		}

		let diskNumber = readUInt16(eocd, 4)
		let directoryDisk = readUInt16(eocd, 6)
		let entriesOnDisk = readUInt16(eocd, 8)
		let totalEntries = readUInt16(eocd, 10)
		let directorySize = readUInt32(eocd, 12)
		let directoryOffset = readUInt32(eocd, 16)

		if totalEntries == 0xFFFF || entriesOnDisk == 0xFFFF {
			throw PyTorchZipArchiveError.zip64Required("entry count")
		}
		if directorySize == 0xFFFF_FFFF { throw PyTorchZipArchiveError.zip64Required("central directory size") }
		if directoryOffset == 0xFFFF_FFFF { throw PyTorchZipArchiveError.zip64Required("central directory offset") }
		if diskNumber == 0xFFFF || directoryDisk == 0xFFFF { throw PyTorchZipArchiveError.zip64Required("disk number") }
		guard diskNumber == 0, directoryDisk == 0 else {
			throw PyTorchZipArchiveError.malformedCentralDirectory("split archives are not supported")
		}
		guard entriesOnDisk == totalEntries else {
			throw PyTorchZipArchiveError.malformedCentralDirectory("entry counts disagree")
		}

		let size = Int(directorySize)
		let offset = Int(directoryOffset)
		guard size <= maximumCentralDirectoryLength else {
			throw PyTorchZipArchiveError.centralDirectoryTooLarge(size)
		}
		guard source.containsRange(offset: offset, count: size) else {
			throw PyTorchZipArchiveError.malformedCentralDirectory("central directory lies outside the file")
		}
		let directoryEnd = offset + size

		// `torch.save` writes the ZIP64 record and locator unconditionally, even for a 518 MB archive
		// whose 32-bit fields are all perfectly valid. Refusing on their *presence* — the obvious
		// reading of "ZIP64 is out of scope" — rejects every file this reader exists for. What is out
		// of scope is ZIP64 being *needed*, which the sentinel checks above cover.
		try validateAdjacency(source, eocdOffset: eocdOffset, directoryEnd: directoryEnd,
							  entryCount: Int(totalEntries), size: size, offset: offset)

		return Directory(entryCount: Int(totalEntries), size: size, offset: offset)
	}

	/// Works out *why* there is no end record at `fileSize - 22`, so the refusal can say something
	/// useful instead of "not a zip".
	///
	/// This searches backwards for an end-record signature — the very scan the reader refuses to use
	/// for locating the directory. It is safe here, and only here, because it is **diagnostic only**:
	/// every path out of this function throws. A false positive can turn one refusal message into
	/// another and can never accept an archive, which is what makes the scan's unreliability
	/// acceptable in a way it never is for parsing.
	private static func diagnoseMissingEndRecord(_ source: any RandomAccessBytes) throws -> PyTorchZipArchiveError {
		// The largest a comment can be, plus the record itself.
		let window = min(65_535 + endOfCentralDirectoryLength, source.totalLength)
		let start = source.totalLength - window
		let bytes = try source.readChecked(at: start, count: window)

		var position = bytes.count - endOfCentralDirectoryLength
		while position >= 0 {
			defer { position -= 1 }
			guard readUInt32(bytes, position) == endOfCentralDirectorySignature else { continue }
			let commentLength = Int(readUInt16(bytes, position + 20))
			let recordEnd = start + position + endOfCentralDirectoryLength + commentLength
			return recordEnd == source.totalLength
				? .zipCommentUnsupported(byteCount: commentLength)
				: .unexpectedTrailingBytes
		}
		return .notAZipArchive
	}

	/// Requires the tail structures to be exactly adjacent to the central directory.
	///
	/// Adjacency is what refuses a `[prefix][complete zip]` polyglot. Such a file has a valid record
	/// at `fileSize - 22`, and its recorded `cdOffset` is relative to the inner archive's start —
	/// smaller than the truth — so any *inequality* here passes and the reader then parses a central
	/// directory belonging to whatever the prefix contains. Only exact equality closes it.
	private static func validateAdjacency(
		_ source: any RandomAccessBytes,
		eocdOffset: Int,
		directoryEnd: Int,
		entryCount: Int,
		size: Int,
		offset: Int
	) throws {
		guard eocdOffset >= zip64LocatorLength else {
			guard directoryEnd == eocdOffset else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("central directory is not adjacent to the end record")
			}
			return
		}

		let locator = try source.readChecked(at: eocdOffset - zip64LocatorLength, count: zip64LocatorLength)
		guard readUInt32(locator, 0) == zip64LocatorSignature else {
			guard directoryEnd == eocdOffset else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("central directory is not adjacent to the end record")
			}
			return
		}

		guard readUInt32(locator, 4) == 0, readUInt32(locator, 16) == 1 else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("locator describes a split archive")
		}
		guard let recordOffset = Int(exactly: readUInt64(locator, 8)) else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("locator offset does not fit")
		}
		guard recordOffset == directoryEnd else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record does not follow the central directory")
		}
		guard source.containsRange(offset: recordOffset, count: zip64EndOfCentralDirectoryLength) else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record lies outside the file")
		}

		let record = try source.readChecked(at: recordOffset, count: zip64EndOfCentralDirectoryLength)
		guard readUInt32(record, 0) == zip64EndOfCentralDirectorySignature else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record signature")
		}
		// The size field counts the bytes after itself, so the record spans 12 + size.
		guard let recordSize = Int(exactly: readUInt64(record, 4)),
			recordSize >= zip64EndOfCentralDirectoryLength - 12,
			let recordSpan = checkedSum(12, recordSize),
			let recordEnd = checkedSum(recordOffset, recordSpan),
			let locatorStart = checkedSum(recordEnd, zip64LocatorLength),
			locatorStart == eocdOffset
		else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record does not abut the locator")
		}
		guard readUInt32(record, 16) == 0, readUInt32(record, 20) == 0 else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record describes a split archive")
		}
		guard readUInt64(record, 24) == UInt64(entryCount),
			readUInt64(record, 32) == UInt64(entryCount),
			readUInt64(record, 40) == UInt64(size),
			readUInt64(record, 48) == UInt64(offset)
		else {
			throw PyTorchZipArchiveError.zip64ChainInconsistent("ZIP64 record disagrees with the classic record")
		}
	}

	private static func readCentralDirectory(
		_ source: any RandomAccessBytes,
		_ directory: Directory
	) throws -> [PyTorchZipEntry] {
		guard directory.entryCount <= maximumEntryCount else {
			throw PyTorchZipArchiveError.tooManyEntries(directory.entryCount)
		}
		let bytes = try source.readChecked(at: directory.offset, count: directory.size)

		var entries: [PyTorchZipEntry] = []
		entries.reserveCapacity(directory.entryCount)
		var cursor = 0
		for _ in 0..<directory.entryCount {
			guard bytes.count - cursor >= centralFileHeaderLength else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("truncated record")
			}
			guard readUInt32(bytes, cursor) == centralFileHeaderSignature else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("record signature")
			}

			let flags = readUInt16(bytes, cursor + 8)
			guard flags & ~permittedFlags == 0 else {
				throw PyTorchZipArchiveError.unsupportedEntryFlags(flags)
			}
			let method = Int(readUInt16(bytes, cursor + 10))
			guard method == 0 else { throw PyTorchZipArchiveError.unsupportedCompression(method: method) }

			let crc = readUInt32(bytes, cursor + 16)
			let compressedSize = readUInt32(bytes, cursor + 20)
			let uncompressedSize = readUInt32(bytes, cursor + 24)
			let nameLength = Int(readUInt16(bytes, cursor + 28))
			let extraLength = Int(readUInt16(bytes, cursor + 30))
			let commentLength = Int(readUInt16(bytes, cursor + 32))
			let diskStart = readUInt16(bytes, cursor + 34)
			let localHeaderOffset = readUInt32(bytes, cursor + 42)

			if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
				throw PyTorchZipArchiveError.zip64Required("entry '\(diagnosticName(bytes, cursor, nameLength))'")
			}
			guard diskStart == 0 else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("entry on another disk")
			}
			// Stored entries record the same value twice; a disagreement means the writer thought the
			// data was compressed, and trusting either number would size the payload wrongly.
			guard compressedSize == uncompressedSize else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("stored entry sizes disagree")
			}
			guard nameLength > 0 else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("empty entry name")
			}
			guard nameLength <= maximumEntryNameLength else {
				throw PyTorchZipArchiveError.entryNameTooLong(nameLength)
			}

			let fixedEnd = cursor + centralFileHeaderLength
			guard let variable = checkedSum(nameLength, extraLength),
				let withComment = checkedSum(variable, commentLength),
				let recordEnd = checkedSum(fixedEnd, withComment),
				recordEnd <= bytes.count
			else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("record overruns the directory")
			}

			let nameBytes = Array(bytes[fixedEnd..<(fixedEnd + nameLength)])
			// Strict UTF-8, deliberately. `String(decoding:as:)` never fails: it substitutes U+FFFD,
			// so two different hostile names collapse into one key and an entry is silently lost
			// rather than the archive being refused. torch writes UTF-8 and sets bit 11 to say so, so
			// a failure here is a real signal.
			guard let name = String(bytes: nameBytes, encoding: .utf8) else {
				throw PyTorchZipArchiveError.entryNameNotUTF8
			}
			try rejectZip64Extra(Array(bytes[(fixedEnd + nameLength)..<(fixedEnd + nameLength + extraLength)]), name: name)

			let size = Int(uncompressedSize)
			let headerOffset = Int(localHeaderOffset)
			guard source.containsRange(offset: headerOffset, count: localFileHeaderLength) else {
				throw PyTorchZipArchiveError.entryOutOfBounds(name: name)
			}
			entries.append(PyTorchZipEntry(
				name: name, uncompressedSize: size, crc32: crc,
				localHeaderOffset: headerOffset, flags: flags, method: UInt16(method)
			))
			cursor = recordEnd
		}

		// Exactly the declared number of records, filling exactly the declared span. Trailing bytes
		// would mean the directory carries something this reader did not account for.
		guard cursor == bytes.count else {
			throw PyTorchZipArchiveError.malformedCentralDirectory("directory has trailing bytes")
		}
		return entries
	}

	/// Refuses a record whose extra field carries ZIP64 sizes.
	///
	/// A ZIP64 extra field moves the real size or offset out of the fixed record, leaving
	/// `0xFFFFFFFF` behind — which the sentinel checks catch — but it can also appear alongside
	/// non-sentinel values. Refusing the header ID outright means there is no arrangement in which a
	/// 32-bit field read here is not the real one. Real ADAF checkpoints carry no extra field at all
	/// in the central directory, so nothing legitimate is lost.
	private static func rejectZip64Extra(_ extra: [UInt8], name: String) throws {
		var cursor = 0
		while cursor < extra.count {
			guard extra.count - cursor >= 4 else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("malformed extra field on '\(name)'")
			}
			let headerID = readUInt16(extra, cursor)
			let size = Int(readUInt16(extra, cursor + 2))
			guard headerID != zip64ExtraHeaderID else {
				throw PyTorchZipArchiveError.zip64Required("extra field on '\(name)'")
			}
			guard let next = checkedSum(cursor + 4, size), next <= extra.count else {
				throw PyTorchZipArchiveError.malformedCentralDirectory("malformed extra field on '\(name)'")
			}
			cursor = next
		}
	}

	/// A name for an error message, before the name has been validated. Never returned to a caller.
	private static func diagnosticName(_ bytes: [UInt8], _ cursor: Int, _ nameLength: Int) -> String {
		let start = cursor + centralFileHeaderLength
		guard nameLength > 0, bytes.count - start >= nameLength else { return "<unnamed>" }
		return String(decoding: bytes[start..<(start + nameLength)], as: UTF8.self)
	}

	// MARK: - Reading an entry

	func entry(named name: String) -> PyTorchZipEntry? {
		index[name].map { entries[$0] }
	}

	/// Reads one entry's bytes, resolving its local header now rather than at open time.
	///
	/// - Parameter maximumByteCount: refused above this, before the read is issued. The caller knows
	///   what it is asking for; the archive does not.
	func bytes(of entry: PyTorchZipEntry, maximumByteCount: Int) throws -> [UInt8] {
		guard entry.uncompressedSize <= maximumByteCount else {
			throw PyTorchZipArchiveError.entryTooLarge(name: entry.name, byteCount: entry.uncompressedSize)
		}
		let dataOffset = try dataOffset(of: entry)
		let payload = try source.readChecked(at: dataOffset, count: entry.uncompressedSize)
		// The checksum binds the payload to the directory record that pointed at it. It is no defence
		// against a hostile archive — an attacker computes a correct CRC trivially — but it is a
		// complete defence against the failure that actually shipped once: an offset resolved to the
		// wrong place, yielding bytes that parse far enough to be believed.
		guard CRC32.checksum(payload) == entry.crc32 else {
			throw PyTorchZipArchiveError.checksumMismatch(name: entry.name)
		}
		return payload
	}

	/// Reads one entry's bytes in bounded chunks, handing each to `receive` as it arrives.
	///
	/// This exists for weight extraction, where a single tensor storage runs to tens of megabytes and
	/// ``bytes(of:maximumByteCount:)`` would materialise all of it. The validation is identical —
	/// both go through ``dataOffset(of:)`` — and the checksum is folded chunk by chunk so it still
	/// covers every byte handed out.
	///
	/// - Important: **`receive` sees bytes before the checksum is known.** The entry's CRC cannot be
	///   verified until the last chunk has been read, so a caller that persists what it receives must
	///   be able to discard *all* of it when this method throws. Nothing here can un-hand a chunk.
	/// - Parameter chunkByteCount: the most bytes held in memory at once. Must be positive.
	func streamBytes(
		of entry: PyTorchZipEntry,
		maximumByteCount: Int,
		chunkByteCount: Int,
		receive: ([UInt8]) throws -> Void
	) throws {
		guard entry.uncompressedSize <= maximumByteCount else {
			throw PyTorchZipArchiveError.entryTooLarge(name: entry.name, byteCount: entry.uncompressedSize)
		}
		precondition(chunkByteCount > 0, "a chunk of no bytes never advances")

		let dataOffset = try dataOffset(of: entry)
		var crc = CRC32.initialValue
		var delivered = 0
		while delivered < entry.uncompressedSize {
			let count = min(chunkByteCount, entry.uncompressedSize - delivered)
			// `dataOffset + delivered` cannot overflow: `dataOffset(of:)` has already proved that
			// `dataOffset + uncompressedSize` is inside the source, and `delivered` never exceeds it.
			let chunk = try source.readChecked(at: dataOffset + delivered, count: count)
			crc = CRC32.update(crc, with: chunk)
			try receive(chunk)
			delivered += count
		}
		guard CRC32.finalize(crc) == entry.crc32 else {
			throw PyTorchZipArchiveError.checksumMismatch(name: entry.name)
		}
	}

	/// Resolves where an entry's payload begins, validating the local header against the central
	/// record that pointed at it.
	///
	/// Kept as one method rather than inlined into each reader so that both ways of reading an entry
	/// are provably subject to the same checks: a validation added here cannot be added to one path
	/// and forgotten on the other.
	private func dataOffset(of entry: PyTorchZipEntry) throws -> Int {
		let header = try source.readChecked(at: entry.localHeaderOffset, count: Self.localFileHeaderLength)
		guard Self.readUInt32(header, 0) == Self.localFileHeaderSignature else {
			throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
		}
		// The local header must agree with the central record on everything that changes what the
		// bytes at the data offset *mean*. Checking only the signature and the name leaves a file free
		// to say "stored, sizes in a descriptor" centrally and something else locally, and the reader
		// would then read a payload the archive describes two ways.
		guard Self.readUInt16(header, 8) == entry.method else {
			throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
		}
		let localFlags = Self.readUInt16(header, 6)
		guard localFlags & ~Self.permittedFlags == 0,
			localFlags & Self.dataDescriptorFlag == entry.flags & Self.dataDescriptorFlag
		else {
			throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
		}
		// With the data-descriptor bit set, torch writes zeroes here and the real sizes live in the
		// central directory; without it, the local sizes must match what the directory claims.
		if entry.flags & Self.dataDescriptorFlag == 0 {
			guard Int(Self.readUInt32(header, 18)) == entry.uncompressedSize,
				Int(Self.readUInt32(header, 22)) == entry.uncompressedSize
			else {
				throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
			}
		}
		let nameLength = Int(Self.readUInt16(header, 26))
		let extraLength = Int(Self.readUInt16(header, 28))

		// The local *name* must match the central record byte for byte — otherwise a central entry
		// called `…/data.pkl` can point at a payload the archive names something else.
		//
		// - Important: the local *extra length* must NOT be compared with the central one. They
		//   legitimately differ: torch writes an extra field purely as padding, so that each entry's
		//   data starts on a 64-byte boundary — 56 bytes of it on `data.pkl`, against 0 in the
		//   central record, which is exactly what puts that payload at offset 128. Requiring them to
		//   match looks like tidying up an inconsistency and rejects every real checkpoint. That is
		//   AIA-0654's bug wearing different clothes.
		let expectedName = Array(entry.name.utf8)
		guard nameLength == expectedName.count else {
			throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
		}
		let nameStart = entry.localHeaderOffset + Self.localFileHeaderLength
		guard Array(try source.readChecked(at: nameStart, count: nameLength)) == expectedName else {
			throw PyTorchZipArchiveError.localHeaderMismatch(name: entry.name)
		}

		guard let afterName = checkedSum(nameStart, nameLength),
			let dataOffset = checkedSum(afterName, extraLength),
			let dataEnd = checkedSum(dataOffset, entry.uncompressedSize),
			source.containsRange(offset: dataOffset, count: entry.uncompressedSize),
			// Entries live before the directory that describes them. Without this, a crafted local
			// header and payload can be hidden inside a central record's comment and reached by
			// pointing `localHeaderOffset` back into the directory.
			dataEnd <= directoryOffset
		else {
			throw PyTorchZipArchiveError.entryOutOfBounds(name: entry.name)
		}
		return dataOffset
	}

	// MARK: - The torch layout

	/// The archive's single root directory and its `data.pkl` entry.
	///
	/// `torch.save` names every entry `<root>/…`, where the root is one component derived from the
	/// checkpoint's filename. Requiring exactly that shape — one component of
	/// `[A-Za-z0-9._-]{1,255}` — is one positive rule in place of four negative ones: it excludes a
	/// multi-component root, `..`, NUL, backslashes and control characters together, and nothing in
	/// the reader then has to reason about what a strange root might mean.
	func torchPickleEntry() throws -> (root: String, entry: PyTorchZipEntry) {
		let candidates = entries.filter { $0.name == "data.pkl" || $0.name.hasSuffix("/data.pkl") }
		guard candidates.isEmpty == false else { throw PyTorchZipArchiveError.pickleEntryNotFound }
		guard candidates.count == 1 else {
			throw PyTorchZipArchiveError.ambiguousPickleEntry(count: candidates.count)
		}

		let entry = candidates[0]
		guard entry.name != "data.pkl" else { throw PyTorchZipArchiveError.unsupportedRoot("") }
		let root = String(entry.name.dropLast("/data.pkl".count))
		// The character class alone admits `.` and `..`, which are exactly the roots that must not
		// pass — so the rule is "one component of these characters, containing something that is not
		// punctuation". Nothing here reaches the filesystem, but the root is concatenated into 900-odd
		// lookup keys and can reach a log line, and a rule that reads as safe while admitting `..` is
		// worse than no rule.
		guard root.isEmpty == false, root.count <= 255,
			root.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }),
			root.contains(where: { $0.isLetter || $0.isNumber })
		else {
			throw PyTorchZipArchiveError.unsupportedRoot(root)
		}
		return (root, entry)
	}

	// MARK: - Little-endian field reads

	private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
		UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
	}

	private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
		UInt32(bytes[offset])
			| (UInt32(bytes[offset + 1]) << 8)
			| (UInt32(bytes[offset + 2]) << 16)
			| (UInt32(bytes[offset + 3]) << 24)
	}

	private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
		var value: UInt64 = 0
		for index in (0..<8).reversed() {
			value = (value << 8) | UInt64(bytes[offset + index])
		}
		return value
	}
}

/// `a + b`, or nil when it overflows.
///
/// Every offset in a zip record is attacker-chosen, and a wrapped sum lands back inside the file's
/// bounds — so a bounds check downstream would pass on a range that was never computed. Returning
/// nil keeps the failure at the arithmetic instead of at whatever the wrapped value happens to hit.
func checkedSum(_ a: Int, _ b: Int) -> Int? {
	let (value, overflow) = a.addingReportingOverflow(b)
	return overflow ? nil : value
}

/// `a * b`, or nil when it overflows. Same reasoning as ``checkedSum(_:_:)``: an element count read
/// out of a checkpoint is attacker-chosen, and a wrapped product compares as a plausible size.
func checkedProduct(_ a: Int, _ b: Int) -> Int? {
	let (value, overflow) = a.multipliedReportingOverflow(by: b)
	return overflow ? nil : value
}
