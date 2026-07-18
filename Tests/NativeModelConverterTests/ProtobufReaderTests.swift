//
//  ProtobufReaderTests.swift
//  NativeModelConverterTests
//

import XCTest
@testable import NativeModelConverter

final class ProtobufReaderTests: XCTestCase {

	func testReader_roundTripsEncoderOutput() throws {
		let inner = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendVarintField(1, value: 300, to: &message) // multi-byte varint
			CoreMLProtobufEncoder.appendStringField(2, value: "hello", to: &message)
		}
		let outer = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendMessageField(5, value: inner, to: &message)
			CoreMLProtobufEncoder.appendVarintField(3, value: 7, to: &message)
			CoreMLProtobufEncoder.appendFloatField(4, value: 1.5, to: &message)
		}

		let fields = try ProtobufReader.fields(in: outer)
		XCTAssertEqual(fields.firstVarint(3), 7)

		let floatValue = fields.first { $0.field == 4 }?.value
		guard case .fixed32(let bits)? = floatValue else {
			return XCTFail("Expected field 4 to be a 32-bit value.")
		}
		XCTAssertEqual(Float(bitPattern: bits), 1.5)

		let innerData = try XCTUnwrap(fields.firstBytes(5))
		let innerFields = try ProtobufReader.fields(in: innerData)
		XCTAssertEqual(innerFields.firstVarint(1), 300)
		XCTAssertEqual(innerFields.firstString(2), "hello")
	}

	func testReader_repeatedFields_preserveOrder() throws {
		let message = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendStringField(1, value: "a", to: &message)
			CoreMLProtobufEncoder.appendStringField(1, value: "b", to: &message)
			CoreMLProtobufEncoder.appendStringField(1, value: "c", to: &message)
		}

		let strings = try ProtobufReader.fields(in: message).allBytes(1).map { String(data: $0, encoding: .utf8) }
		XCTAssertEqual(strings, ["a", "b", "c"])
	}

	func testReader_truncatedLengthDelimited_throws() {
		// A length prefix claiming more bytes than remain must fail rather than read out of bounds.
		let malformed = Data([0x0A, 0x05, 0x01, 0x02]) // field 1, wire 2, length 5, only 2 bytes follow
		XCTAssertThrowsError(try ProtobufReader.fields(in: malformed)) { error in
			XCTAssertEqual(error as? ProtobufReaderError, .truncated)
		}
	}
}
