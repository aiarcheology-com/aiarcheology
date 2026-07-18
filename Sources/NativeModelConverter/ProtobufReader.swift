//
//  ProtobufReader.swift
//  NativeModelConverter
//
//  Minimal, dependency-free protobuf wire-format decoder.
//

import Foundation

/// A decoded protobuf field value, tagged by its wire type.
///
/// This is the read-side counterpart to ``CoreMLProtobufEncoder``. It intentionally understands only
/// the wire types used by the source formats the converter reads (ONNX, and later TFLite is a
/// FlatBuffer and does not use this): varint, 64-bit, length-delimited, and 32-bit. Deprecated group
/// wire types (3 and 4) are rejected rather than skipped, because no supported input uses them.
enum ProtobufValue: Equatable {
	case varint(UInt64)
	case fixed64(UInt64)
	case lengthDelimited(Data)
	case fixed32(UInt32)
}

enum ProtobufReaderError: Error, Equatable {
	case truncated
	case unsupportedWireType(Int)
	case malformedVarint
}

/// Decodes a protobuf message into its fields, preserving order and repetition.
///
/// The decoder returns a flat list of `(fieldNumber, value)` pairs. A parser for a specific message
/// interprets those fields; unknown field numbers are simply ignored by the parser, which gives the
/// forward compatibility protobuf is designed for.
enum ProtobufReader {
	/// Decodes every top-level field in `data`.
	static func fields(in data: Data) throws -> [(field: Int, value: ProtobufValue)] {
		var fields: [(field: Int, value: ProtobufValue)] = []
		try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			let bytes = raw.bindMemory(to: UInt8.self)
			var cursor = 0
			while cursor < bytes.count {
				let tag = try readVarint(bytes, &cursor)
				let fieldNumber = Int(tag >> 3)
				let wireType = Int(tag & 0x7)
				switch wireType {
				case 0:
					fields.append((fieldNumber, .varint(try readVarint(bytes, &cursor))))
				case 1:
					fields.append((fieldNumber, .fixed64(try readFixed(bytes, &cursor, count: 8))))
				case 2:
					// A crafted length can exceed Int.max; `Int(exactly:)` fails instead of trapping, and
					// comparing against the remaining bytes avoids a `cursor + length` overflow.
					let lengthValue = try readVarint(bytes, &cursor)
					guard let length = Int(exactly: lengthValue), length <= bytes.count - cursor else {
						throw ProtobufReaderError.truncated
					}
					fields.append((fieldNumber, .lengthDelimited(Data(bytes: raw.baseAddress!.advanced(by: cursor), count: length))))
					cursor += length
				case 5:
					fields.append((fieldNumber, .fixed32(UInt32(try readFixed(bytes, &cursor, count: 4)))))
				default:
					throw ProtobufReaderError.unsupportedWireType(wireType)
				}
			}
		}
		return fields
	}

	private static func readVarint(_ bytes: UnsafeBufferPointer<UInt8>, _ cursor: inout Int) throws -> UInt64 {
		var result: UInt64 = 0
		var shift: UInt64 = 0
		while true {
			guard cursor < bytes.count else { throw ProtobufReaderError.truncated }
			let byte = bytes[cursor]
			cursor += 1
			guard shift < 64 else { throw ProtobufReaderError.malformedVarint }
			// The 10th byte (shift 63) may only carry bit 63; a larger payload is an overlong/overflowing
			// varint and would silently drop bits, so reject it.
			guard shift < 63 || byte & 0x7F <= 1 else { throw ProtobufReaderError.malformedVarint }
			result |= UInt64(byte & 0x7F) << shift
			if byte & 0x80 == 0 { break }
			shift += 7
		}
		return result
	}

	private static func readFixed(_ bytes: UnsafeBufferPointer<UInt8>, _ cursor: inout Int, count: Int) throws -> UInt64 {
		guard cursor + count <= bytes.count else { throw ProtobufReaderError.truncated }
		var value: UInt64 = 0
		for index in 0 ..< count {
			value |= UInt64(bytes[cursor + index]) << (8 * index)
		}
		cursor += count
		return value
	}

	/// Decodes a packed sequence of varints — the length-delimited payload a repeated scalar field
	/// carries when the producer chose the packed encoding.
	static func packedVarints(in data: Data) throws -> [UInt64] {
		var values: [UInt64] = []
		try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			let bytes = raw.bindMemory(to: UInt8.self)
			var cursor = 0
			while cursor < bytes.count {
				values.append(try readVarint(bytes, &cursor))
			}
		}
		return values
	}
}

extension Array where Element == (field: Int, value: ProtobufValue) {
	/// The bytes of the first length-delimited field with this number, if present.
	func firstBytes(_ field: Int) -> Data? {
		for entry in self where entry.field == field {
			if case .lengthDelimited(let data) = entry.value { return data }
		}
		return nil
	}

	/// The bytes of every length-delimited field with this number, in order.
	func allBytes(_ field: Int) -> [Data] {
		compactMap { entry in
			guard entry.field == field, case .lengthDelimited(let data) = entry.value else { return nil }
			return data
		}
	}

	/// The first varint field with this number, if present.
	func firstVarint(_ field: Int) -> UInt64? {
		for entry in self where entry.field == field {
			if case .varint(let value) = entry.value { return value }
		}
		return nil
	}

	/// Every integer value of a repeated field, accepting both the unpacked encoding (individual
	/// varint entries) and the packed encoding (a single length-delimited blob of varints). ONNX
	/// producers use either for `TensorProto.dims` and `AttributeProto.ints`.
	func repeatedInts(_ field: Int) throws -> [Int] {
		var values: [Int] = []
		for entry in self where entry.field == field {
			switch entry.value {
			case .varint(let value):
				values.append(Int(bitPattern: UInt(value)))
			case .lengthDelimited(let data):
				values.append(contentsOf: try ProtobufReader.packedVarints(in: data).map { Int(bitPattern: UInt($0)) })
			default:
				break
			}
		}
		return values
	}

	/// The first UTF-8 string field with this number, if present.
	func firstString(_ field: Int) -> String? {
		firstBytes(field).flatMap { String(data: $0, encoding: .utf8) }
	}
}
