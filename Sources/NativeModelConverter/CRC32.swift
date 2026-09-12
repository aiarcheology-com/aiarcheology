//
//  CRC32.swift
//  NativeModelConverter
//
//  The checksum zip records carry, so a resolved payload can be checked against its entry (AIA-0666).
//

import Foundation

/// CRC-32 as zip uses it: the IEEE polynomial in reflected form (`0xEDB88320`), initial and final
/// value `0xFFFFFFFF`.
///
/// Hand-rolled rather than pulled from zlib because the package deliberately carries no
/// dependencies, and because the only caller checks two entries of a few hundred kilobytes.
enum CRC32 {
	private static let table: [UInt32] = {
		(0..<256).map { index -> UInt32 in
			var value = UInt32(index)
			for _ in 0..<8 {
				value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
			}
			return value
		}
	}()

	/// The value a running checksum starts from.
	static let initialValue: UInt32 = 0xFFFF_FFFF

	/// Folds one chunk into a running checksum.
	///
	/// The incremental form exists because a weight blob is streamed: holding a 51 MB tensor in
	/// memory only to checksum it would defeat the bounded-memory point of streaming it at all. The
	/// fold is byte-for-byte the one ``checksum(_:)`` performs, which is why that method is now
	/// written in terms of these two rather than kept as a second copy that could drift.
	static func update(_ crc: UInt32, with bytes: [UInt8]) -> UInt32 {
		var crc = crc
		for byte in bytes {
			crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
		}
		return crc
	}

	/// Turns a running checksum into the value a zip record carries.
	static func finalize(_ crc: UInt32) -> UInt32 {
		crc ^ 0xFFFF_FFFF
	}

	static func checksum(_ bytes: [UInt8]) -> UInt32 {
		finalize(update(initialValue, with: bytes))
	}
}
