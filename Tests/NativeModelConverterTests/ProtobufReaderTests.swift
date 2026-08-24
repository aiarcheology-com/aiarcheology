//
//  ProtobufReaderTests.swift
//  NativeModelConverterTests
//

import Foundation
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

	func testReader_oversizedLength_throwsInsteadOfTrapping() {
		// field 1, wire 2, length = 0xFFFFFFFFFFFFFFFF (> Int.max). Must throw, not trap on Int(...).
		let malformed = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
		XCTAssertThrowsError(try ProtobufReader.fields(in: malformed)) { error in
			XCTAssertEqual(error as? ProtobufReaderError, .truncated)
		}
	}

	func testReader_overlongVarint_throws() {
		// 10 continuation bytes with a non-1 final payload overflow a UInt64 and must be rejected.
		let malformed = Data([0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02])
		XCTAssertThrowsError(try ProtobufReader.fields(in: malformed)) { error in
			XCTAssertEqual(error as? ProtobufReaderError, .malformedVarint)
		}
	}

	func testReader_repeatedInts_decodesPackedAndUnpacked() throws {
		// Unpacked: three field-1 varints. Packed: one length-delimited field-2 blob of three varints.
		let unpacked = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendVarintField(1, value: 2, to: &message)
			CoreMLProtobufEncoder.appendVarintField(1, value: 3, to: &message)
			CoreMLProtobufEncoder.appendVarintField(1, value: 5, to: &message)
		}
		let packedPayload = Data([2, 3, 5]) // three single-byte varints, packed
		let packed = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendMessageField(2, value: packedPayload, to: &message)
		}
		XCTAssertEqual(try ProtobufReader.fields(in: unpacked).repeatedInts(1), [2, 3, 5])
		XCTAssertEqual(try ProtobufReader.fields(in: packed).repeatedInts(2), [2, 3, 5])
	}

	func testStreamingEncoder_countPassAndDeferredWriteMatchTheInMemoryWireFormat() throws {
		let payload = Data([0x00, 0x7F, 0x80, 0xFF])
		var inner = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendStringField(1, value: "streamed", to: &inner)
		CoreMLProtobufStreamingEncoder.appendDeferredPayloadField(
			2,
			payload: CoreMLProtobufDeferredPayload(byteCount: UInt64(payload.count)) { handle in
				try handle.write(contentsOf: payload)
			},
			to: &inner
		)
		var outer = CoreMLProtobufSegments()
		CoreMLProtobufStreamingEncoder.appendMessageField(9, value: inner, to: &outer)

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let output = directory.appendingPathComponent("streamed.bin")
		try NativeModelAtomicFilePublisher.writeAtomically(
			to: output,
			writing: { handle in try outer.write(to: handle, reporting: nil) },
			beforePublish: {}
		)

		let expectedInner = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendStringField(1, value: "streamed", to: &message)
			CoreMLProtobufEncoder.appendMessageField(2, value: payload, to: &message)
		}
		let expected = CoreMLProtobufEncoder.message { message in
			CoreMLProtobufEncoder.appendMessageField(9, value: expectedInner, to: &message)
		}
		let actual = try Data(contentsOf: output)
		XCTAssertEqual(actual, expected)
		XCTAssertEqual(outer.byteCount, UInt64(actual.count))
	}

	func testStreamingSegments_markerOffsetAccountsForDeferredPayloads() {
		let marker = Data("marker".utf8)
		var segments = CoreMLProtobufSegments()
		segments.append(data: Data("prefix".utf8))
		segments.append(deferred: CoreMLProtobufDeferredPayload(byteCount: 4) { _ in })
		segments.append(data: marker)

		XCTAssertEqual(segments.firstFileOffset(of: marker), 10)
	}

	func testAtomicPublisher_cancellationBeforePublishPreservesExistingArtifactAndCleansTemporaryFile() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("model.mlmodel")
		let previous = Data("established artifact".utf8)
		try previous.write(to: destination)

		XCTAssertThrowsError(
			try NativeModelAtomicFilePublisher.writeAtomically(
				to: destination,
				writing: { handle in try handle.write(contentsOf: Data("new artifact".utf8)) },
				beforePublish: { throw PublisherTestError.cancelled }
			)
		)
		XCTAssertEqual(try Data(contentsOf: destination), previous)
		let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		XCTAssertEqual(remainingNames, [destination.lastPathComponent])
	}
}

private enum PublisherTestError: Error {
	case cancelled
}
