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

	static func checksum(_ bytes: [UInt8]) -> UInt32 {
		var crc: UInt32 = 0xFFFF_FFFF
		for byte in bytes {
			crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
		}
		return crc ^ 0xFFFF_FFFF
	}
}
