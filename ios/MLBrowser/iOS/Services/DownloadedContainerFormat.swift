//
//  DownloadedContainerFormat.swift
//  AI Archeology
//
//  Content sniffing for directly-downloaded model files (AIA-0654).
//

import Foundation

/// What a directly-downloaded file turned out to be, judged by its bytes rather than its name.
///
/// A URL download is stored under the URLSession temporary name, so the extension says nothing
/// about the contents — and the one thing the app must never do is decide by the *download URL's*
/// extension, which the user can edit after the bytes have already arrived.
///
/// Only formats the app recognises **and cannot import** are named here. Everything else is
/// ``unrecognized``, which is not a judgement about the file: it means "take the path this file
/// would have taken before AIA-0654". That is what keeps the classification incapable of changing
/// the outcome of any import that works today.
///
/// **Known limit, accepted deliberately.** This decides *before* the converter or Core ML sees the
/// file, so a file crafted to satisfy both this sniff and a supported parser — an ONNX model with an
/// ignored field positioned to put `ustar` at offset 257 and an octal-looking size at 124, say — is
/// rejected rather than imported. No static check closes that: a polyglot can satisfy a checksum
/// too. The alternative is to reject only after the normal path has already failed, which is
/// airtight but makes the app compile a 518 MB non-model before explaining itself, on exactly the
/// files this exists for. Early rejection costs an adversarial case that requires deliberate
/// construction; late rejection costs every genuine one. Nothing here can be triggered by accident:
/// it needs six exact bytes at one exact offset plus a well-formed octal field at another.
enum DownloadedContainerFormat: Equatable {
	/// A PyTorch zip-serialization checkpoint (`torch.save`) — the shape the ADAF models on Zenodo
	/// ship in, despite their `.tar` filenames.
	case pyTorchZipCheckpoint
	/// A POSIX/GNU tar archive. The app has no archive extraction anywhere, so this is recognised
	/// only in order to say so.
	case tarArchive
	/// Anything else, including every format the app imports normally.
	case unrecognized
}

extension DownloadedContainerFormat {
	/// How much of the file is ever read. A sniff must stay cheap and bounded: the files that
	/// motivate this are 518 MB and 862 MB, and the answer lives in the first few hundred bytes.
	private static let prefixByteCount = 4096

	/// Zip local file header: signature, then fixed-offset fields.
	private static let zipLocalHeaderSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04] // "PK\u{03}\u{04}"
	private static let zipLocalHeaderLength = 30
	private static let zipFlagsOffset = 6
	private static let zipCompressedSizeOffset = 18
	private static let zipNameLengthOffset = 26
	private static let zipExtraLengthOffset = 28

	/// A torch archive names every entry `<root>/…`, and the root is a filename, not a path — an
	/// entry name longer than this is not something this app is looking at.
	private static let maximumEntryNameLength = 1024

	/// `torch.save` writes `data.pkl` first, but entry order is a property of the writer, not of the
	/// zip format, so a few leading records are tolerated. The walk stays inside the prefix either
	/// way; this only bounds the work when a hostile file claims many tiny entries.
	private static let maximumZipEntriesInspected = 8

	/// The pickle that carries a torch checkpoint's object graph. Its presence is the whole test —
	/// deliberately no key reading, no decoding, nothing that interprets attacker-controlled data.
	private static let torchPickleEntryName = "data.pkl"

	/// tar header fields (the 512-byte block every variant starts with).
	private static let tarHeaderLength = 512
	private static let tarMagicOffset = 257
	private static let tarSizeOffset = 124
	private static let tarSizeLength = 12

	/// Classifies the file at `url` by reading a bounded prefix of it.
	///
	/// **Total by construction: this never throws and never traps.** Every unreadable file,
	/// directory, empty file, short read, or malformed header answers ``unrecognized``. That
	/// totality is load-bearing rather than tidy — the caller sits on the shared import path, and a
	/// throw escaping from here would break flows that work today (a resumed `.aiagraph` conversion
	/// hands this function a *directory*).
	static func classify(fileAt url: URL) -> DownloadedContainerFormat {
		guard let prefix = readPrefix(of: url), prefix.isEmpty == false else {
			return .unrecognized
		}
		if containsTorchPickleEntry(prefix) {
			return .pyTorchZipCheckpoint
		}
		if isTarHeader(prefix) {
			return .tarArchive
		}
		return .unrecognized
	}

	/// Reads at most ``prefixByteCount`` bytes, answering `nil` for anything that is not a readable
	/// file. `FileHandle(forReadingFrom:)` throws for a directory, which is the resumed-conversion
	/// case; `read(upToCount:)` short-reads rather than failing near the end of a small file.
	private static func readPrefix(of url: URL) -> [UInt8]? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		guard let data = try? handle.read(upToCount: prefixByteCount) else { return nil }
		return [UInt8](data)
	}

	/// Walks up to ``maximumZipEntriesInspected`` local file headers looking for the torch pickle.
	///
	/// Every offset is bounds-checked against the prefix before it is read, and the walk stops
	/// rather than guessing whenever the archive stops looking like a plainly-written zip. A file
	/// that stops the walk is reported ``unrecognized``, i.e. it keeps today's behaviour — being
	/// wrong in that direction costs a worse error message, while being wrong in the other
	/// direction would reroute an import that works.
	private static func containsTorchPickleEntry(_ bytes: [UInt8]) -> Bool {
		guard bytes.starts(with: zipLocalHeaderSignature) else { return false }

		var offset = 0
		for _ in 0..<maximumZipEntriesInspected {
			guard offset >= 0, bytes.count - offset >= zipLocalHeaderLength else { return false }
			guard Array(bytes[offset..<(offset + zipLocalHeaderSignature.count)]) == zipLocalHeaderSignature else {
				return false
			}

			let flags = readUInt16(bytes, at: offset + zipFlagsOffset)
			// General-purpose bit 3: sizes are written *after* the data, in a trailing descriptor, so
			// the header's size field is zero and the next header's offset cannot be computed from it.
			// Stop instead of walking to a garbage offset. `torch.save` writes stored entries with
			// known sizes, so this only ever fires on foreign or hostile archives.
			guard flags & 0x0008 == 0 else { return false }

			let nameLength = Int(readUInt16(bytes, at: offset + zipNameLengthOffset))
			let extraLength = Int(readUInt16(bytes, at: offset + zipExtraLengthOffset))
			let compressedSize = Int(readUInt32(bytes, at: offset + zipCompressedSizeOffset))
			guard nameLength > 0, nameLength <= maximumEntryNameLength else { return false }

			let nameStart = offset + zipLocalHeaderLength
			guard bytes.count - nameStart >= nameLength else { return false }
			if isTorchPickleEntryName(Array(bytes[nameStart..<(nameStart + nameLength)])) {
				return true
			}

			// Overflow-safe advance; a hostile size field must not wrap the offset into range.
			let (afterName, nameOverflow) = nameStart.addingReportingOverflow(nameLength)
			guard nameOverflow == false else { return false }
			let (afterExtra, extraOverflow) = afterName.addingReportingOverflow(extraLength)
			guard extraOverflow == false else { return false }
			let (next, sizeOverflow) = afterExtra.addingReportingOverflow(compressedSize)
			guard sizeOverflow == false, next > offset else { return false }
			offset = next
		}
		return false
	}

	/// True for `data.pkl` and for any `<root>/data.pkl`. Compared as bytes: an entry name is not
	/// required to be valid UTF-8, and decoding attacker-controlled bytes to compare them would add
	/// a step that can only introduce surprises.
	private static func isTorchPickleEntryName(_ name: [UInt8]) -> Bool {
		let expected = [UInt8](torchPickleEntryName.utf8)
		guard name.count >= expected.count, name.suffix(expected.count).elementsEqual(expected) else {
			return false
		}
		if name.count == expected.count { return true }
		return name[name.count - expected.count - 1] == UInt8(ascii: "/")
	}

	/// A tar header: the `ustar` magic **plus** a well-formed octal `size`.
	///
	/// The magic alone is not enough — 5 bytes can appear anywhere in an arbitrary file — and a
	/// false positive here would swap a cryptic failure for a confidently wrong message. One
	/// corroborating field is the proportionate answer: nothing destructive follows this branch, so
	/// a checksum (with its signed/unsigned-char variance across historic writers) would buy
	/// nothing. **V7 tars are out of scope**: they carry no magic at all, so they fall through to
	/// ``unrecognized``, which is exactly today's behaviour for them. So does GNU's base-256 size
	/// encoding for entries above 8 GB, for the same reason and with the same harmless consequence.
	private static func isTarHeader(_ bytes: [UInt8]) -> Bool {
		guard bytes.count >= tarHeaderLength else { return false }
		let posix: [UInt8] = Array("ustar\0".utf8)
		let gnu: [UInt8] = Array("ustar  ".utf8)
		let magic = Array(bytes[tarMagicOffset..<min(tarMagicOffset + gnu.count, bytes.count)])
		guard magic.starts(with: posix) || magic.starts(with: gnu) else { return false }
		return isValidOctalField(Array(bytes[tarSizeOffset..<(tarSizeOffset + tarSizeLength)]))
	}

	/// A tar numeric field: octal digits, then NUL or space padding, and at least one digit.
	private static func isValidOctalField(_ field: [UInt8]) -> Bool {
		var sawDigit = false
		var sawTerminator = false
		for byte in field {
			switch byte {
			case UInt8(ascii: "0")...UInt8(ascii: "7"):
				// A digit after the padding has begun means this is not a tar numeric field.
				if sawTerminator { return false }
				sawDigit = true
			case 0x00, UInt8(ascii: " "):
				sawTerminator = true
			default:
				return false
			}
		}
		return sawDigit
	}

	private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
		UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
	}

	private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
		UInt32(bytes[offset])
			| (UInt32(bytes[offset + 1]) << 8)
			| (UInt32(bytes[offset + 2]) << 16)
			| (UInt32(bytes[offset + 3]) << 24)
	}
}
