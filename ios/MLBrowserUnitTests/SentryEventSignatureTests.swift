//
//  SentryEventSignatureTests.swift
//  AI ArcheologyTests
//

import XCTest
@testable import ML_Browser

final class SentryEventSignatureTests: XCTestCase {
	
	func testSignatureHex_sameInput_isStable() {
		let input = SentryEventSignatureInput(
			errorType: "MyError",
			message: "Something bad happened",
			topFrames: ["a()", "b()", "c()"]
		)
		
		let s1 = SentryEventSignatureBuilder.signatureHex(from: input)
		let s2 = SentryEventSignatureBuilder.signatureHex(from: input)
		
		XCTAssertEqual(s1, s2)
		
		// Ensure we actually received a 16-byte hex string (32 hex characters).
		guard let signature = s1 else {
			XCTFail("Expected non-nil signature hex")
			return
		}
		
		XCTAssertEqual(signature.count, 32) // 32 hex characters (16 bytes)
		
		let allowedHexCharacters = "0123456789abcdef"
		let lowercasedSignature = signature.lowercased()
		XCTAssertTrue(
			lowercasedSignature.allSatisfy { allowedHexCharacters.contains($0) },
			"Signature contains non-hex characters: \(signature)"
		)
	}
	
	func testSignatureHex_redactsUUIDs() {
		let input1 = SentryEventSignatureInput(
			errorType: "NetworkError",
			message: "Request failed id=9E5E0B5B-8B0C-4B12-9EAA-2A3D12B13A0C",
			topFrames: ["fetch()", "run()"]
		)
		let input2 = SentryEventSignatureInput(
			errorType: "NetworkError",
			message: "Request failed id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
			topFrames: ["fetch()", "run()"]
		)
		
		// Verify that the redaction actually produces identical normalized strings
		// Both messages should become "Request failed id=<uuid>"
		let normalized1 = input1.message?.replacingOccurrences(
			of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
			with: "<uuid>",
			options: .regularExpression
		)
		let normalized2 = input2.message?.replacingOccurrences(
			of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
			with: "<uuid>",
			options: .regularExpression
		)
		XCTAssertEqual(normalized1, normalized2, "Redaction should produce identical normalized strings")
		
		XCTAssertEqual(
			SentryEventSignatureBuilder.signatureHex(from: input1),
			SentryEventSignatureBuilder.signatureHex(from: input2)
		)
	}
	
	func testSignatureHex_differentFrames_produceDifferentSignature() {
		let base = SentryEventSignatureInput(
			errorType: "MyError",
			message: "Oops",
			topFrames: ["a()", "b()"]
		)
		let changed = SentryEventSignatureInput(
			errorType: "MyError",
			message: "Oops",
			topFrames: ["a()", "x()"]
		)
		
		XCTAssertNotEqual(
			SentryEventSignatureBuilder.signatureHex(from: base),
			SentryEventSignatureBuilder.signatureHex(from: changed)
		)
	}
	
	func testSignatureHex_emptyInput_returnsNil() {
		let input = SentryEventSignatureInput(errorType: nil, message: nil, topFrames: [])
		XCTAssertNil(SentryEventSignatureBuilder.signatureHex(from: input))
	}
	
	func testSignatureHex_redactsTimestamps() {
		let input1 = SentryEventSignatureInput(
			errorType: nil,
			message: "Failed at 2025-12-22T10:11:12Z",
			topFrames: []
		)
		let input2 = SentryEventSignatureInput(
			errorType: nil,
			message: "Failed at 2023-01-15T03:45:00.123456Z",
			topFrames: []
		)
		let input3 = SentryEventSignatureInput(
			errorType: nil,
			message: "Failed at 2024-06-30 14:20:30",
			topFrames: []
		)
		
		// All should produce the same signature after timestamp redaction
		let sig1 = SentryEventSignatureBuilder.signatureHex(from: input1)
		let sig2 = SentryEventSignatureBuilder.signatureHex(from: input2)
		let sig3 = SentryEventSignatureBuilder.signatureHex(from: input3)
		
		XCTAssertEqual(sig1, sig2)
		XCTAssertEqual(sig2, sig3)
	}
	
	func testSignatureHex_redactsEpochTimestamps() {
		let input1 = SentryEventSignatureInput(
			errorType: nil,
			message: "Error at epoch 1234567890",
			topFrames: []
		)
		let input2 = SentryEventSignatureInput(
			errorType: nil,
			message: "Error at epoch 9876543210",
			topFrames: []
		)
		
		XCTAssertEqual(
			SentryEventSignatureBuilder.signatureHex(from: input1),
			SentryEventSignatureBuilder.signatureHex(from: input2)
		)
	}
	
	func testSignatureHex_redactsHexStrings() {
		let input1 = SentryEventSignatureInput(
			errorType: nil,
			message: "Address 0xdeadbeef12345678 failed",
			topFrames: []
		)
		let input2 = SentryEventSignatureInput(
			errorType: nil,
			message: "Address 0xabcdef9876543210 failed",
			topFrames: []
		)
		
		XCTAssertEqual(
			SentryEventSignatureBuilder.signatureHex(from: input1),
			SentryEventSignatureBuilder.signatureHex(from: input2)
		)
		
		// Long hex without 0x prefix
		let input3 = SentryEventSignatureInput(
			errorType: nil,
			message: "Hash abcdef1234567890abcdef1234567890 invalid",
			topFrames: []
		)
		let input4 = SentryEventSignatureInput(
			errorType: nil,
			message: "Hash 1234567890abcdef1234567890abcdef invalid",
			topFrames: []
		)
		
		XCTAssertEqual(
			SentryEventSignatureBuilder.signatureHex(from: input3),
			SentryEventSignatureBuilder.signatureHex(from: input4)
		)
	}
	
	func testSignatureHex_doesNotRedactShortHex() {
		// Short hex strings (< 16 chars) should NOT be redacted
		let input1 = SentryEventSignatureInput(
			errorType: nil,
			message: "Code 0xabc failed",
			topFrames: []
		)
		let input2 = SentryEventSignatureInput(
			errorType: nil,
			message: "Code 0xdef failed",
			topFrames: []
		)
		
		// These should produce DIFFERENT signatures since short hex isn't redacted
		XCTAssertNotEqual(
			SentryEventSignatureBuilder.signatureHex(from: input1),
			SentryEventSignatureBuilder.signatureHex(from: input2)
		)
	}
	
	func testSignatureHex_truncatesLongMessages() {
		// Test that messages longer than 500 characters are truncated
		let longMessage = String(repeating: "A", count: 600)
		let input = SentryEventSignatureInput(
			errorType: "TestError",
			message: longMessage,
			topFrames: []
		)
		
		// Build signature - should not crash and should truncate
		let signature = SentryEventSignatureBuilder.signatureHex(from: input)
		XCTAssertNotNil(signature)
		
		// Verify truncation by checking that two different long messages
		// with the same 500-char prefix produce the same signature
		let longMessage2 = String(repeating: "A", count: 500) + String(repeating: "B", count: 100)
		let input2 = SentryEventSignatureInput(
			errorType: "TestError",
			message: longMessage2,
			topFrames: []
		)
		
		XCTAssertEqual(
			SentryEventSignatureBuilder.signatureHex(from: input),
			SentryEventSignatureBuilder.signatureHex(from: input2),
			"Messages with same 500-char prefix should produce identical signatures"
		)
	}
}


