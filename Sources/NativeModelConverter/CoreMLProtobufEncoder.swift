//
//  CoreMLProtobufEncoder.swift
//  NativeModelConverter
//
//  Minimal, dependency-free protobuf writer for the Core ML neural-network model subset.
//

import Foundation

/// Encodes the protobuf wire types used by the first native Core ML emitter.
///
/// This is deliberately a small encoder, rather than a copy of the generated Core ML protobuf
/// surface. It covers only the fields emitted by `NativeModelCoreMLEmitter`; every field number is
/// verified against Apple's public Core ML model specification.
enum CoreMLProtobufEncoder {

	static func message(_ body: (inout Data) -> Void) -> Data {
		var data = Data()
		body(&data)
		return data
	}

	static func appendVarintField(_ fieldNumber: Int, value: UInt64, to data: inout Data) {
		appendKey(fieldNumber, wireType: 0, to: &data)
		appendVarint(value, to: &data)
	}

	static func appendStringField(_ fieldNumber: Int, value: String, to data: inout Data) {
		appendLengthDelimitedField(fieldNumber, value: Data(value.utf8), to: &data)
	}

	static func appendMessageField(_ fieldNumber: Int, value: Data, to data: inout Data) {
		appendLengthDelimitedField(fieldNumber, value: value, to: &data)
	}

	static func appendFloatField(_ fieldNumber: Int, value: Float, to data: inout Data) {
		appendKey(fieldNumber, wireType: 5, to: &data)
		var littleEndianBits = value.bitPattern.littleEndian
		withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
	}

	/// Core ML declares NMS thresholds as `double`, which is wire type 1 — writing them as floats
	/// would shift every following field and corrupt the message.
	static func appendDoubleField(_ fieldNumber: Int, value: Double, to data: inout Data) {
		appendKey(fieldNumber, wireType: 1, to: &data)
		var littleEndianBits = value.bitPattern.littleEndian
		withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
	}

	/// A packed `repeated` scalar field: proto3 encodes these as one length-delimited run of
	/// varints, which is how Core ML writes shape and permutation vectors.
	static func appendPackedVarintField(_ fieldNumber: Int, values: [UInt64], to data: inout Data) {
		var payload = Data()
		for value in values {
			appendVarint(value, to: &payload)
		}
		appendLengthDelimitedField(fieldNumber, value: payload, to: &data)
	}

	/// Writes a signed `int64` field. Negative values occupy the full ten-byte varint (two's
	/// complement, *not* zigzag — that is `sint64`), which is how Core ML encodes an unbounded
	/// shape-range upper bound of -1.
	static func appendSignedVarintField(_ fieldNumber: Int, value: Int64, to data: inout Data) {
		appendKey(fieldNumber, wireType: 0, to: &data)
		appendVarint(UInt64(bitPattern: value), to: &data)
	}

	private static func appendKey(_ fieldNumber: Int, wireType: UInt64, to data: inout Data) {
		precondition(fieldNumber > 0)
		appendVarint((UInt64(fieldNumber) << 3) | wireType, to: &data)
	}

	private static func appendLengthDelimitedField(_ fieldNumber: Int, value: Data, to data: inout Data) {
		appendKey(fieldNumber, wireType: 2, to: &data)
		appendVarint(UInt64(value.count), to: &data)
		data.append(value)
	}

	private static func appendVarint(_ value: UInt64, to data: inout Data) {
		var remaining = value
		while remaining >= 0x80 {
			data.append(UInt8(remaining & 0x7F) | 0x80)
			remaining >>= 7
		}
		data.append(UInt8(remaining))
	}
}
