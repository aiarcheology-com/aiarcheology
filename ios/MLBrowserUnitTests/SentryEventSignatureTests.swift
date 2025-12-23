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
		XCTAssertEqual(s1?.count, 32) // 32 hex characters (16 bytes)
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
}


