//
//  SupportLogKeyCodingTests.swift
//  SupportLogFormatTests
//
//  AIA-0643.
//

import CryptoKit
import Foundation
import XCTest
@testable import SupportLogFormat

/// The fail-closed key parse.
///
/// Criterion 6 of AIA-0643: a missing or malformed public key disables the export entirely. These
/// cases are not hypothetical — an empty string is exactly what a build produces when the value is
/// absent, and the literal `$(…)` placeholder is what an unsubstituted build setting leaves behind.
/// Every one must yield `nil`, because the only alternative to sealing is shipping the log in the
/// clear.
final class SupportLogKeyCodingTests: XCTestCase {

	func testAValidKeyRoundTripsThroughBase64URL() throws {
		let key = Curve25519.KeyAgreement.PrivateKey().publicKey
		let encoded = SupportLogKeyCoding.base64URLEncoded(key.rawRepresentation)

		let decoded = try XCTUnwrap(SupportLogKeyCoding.publicKey(base64URLEncoded: encoded))

		XCTAssertEqual(decoded.rawRepresentation, key.rawRepresentation)
	}

	func testEncodingUsesTheURLAlphabetAndNoPadding() {
		// `+` and `/` appear in ordinary base64 of random bytes; `/` is the dangerous one, because
		// `//` opens a comment in an xcconfig and would silently truncate the value.
		for _ in 0..<200 {
			let encoded = SupportLogKeyCoding.base64URLEncoded(
				Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
			)
			XCTAssertFalse(encoded.contains("+"), "base64url must not emit '+': \(encoded)")
			XCTAssertFalse(encoded.contains("/"), "base64url must not emit '/': \(encoded)")
			XCTAssertFalse(encoded.contains("="), "base64url here is unpadded: \(encoded)")
		}
	}

	/// A key pasted from a tool that emits ordinary base64 still has to work.
	func testOrdinaryBase64IsAlsoAccepted() throws {
		let key = Curve25519.KeyAgreement.PrivateKey().publicKey
		let standard = key.rawRepresentation.base64EncodedString()

		let decoded = try XCTUnwrap(SupportLogKeyCoding.publicKey(base64URLEncoded: standard))

		XCTAssertEqual(decoded.rawRepresentation, key.rawRepresentation)
	}

	func testEveryMalformedKeyFailsClosed() {
		let cases: [(String, String?)] = [
			("absent from Info.plist", nil),
			("empty — what an unset build setting substitutes to", ""),
			("unsubstituted xcconfig placeholder", "$(SUPPORT_LOG_PUBLIC_KEY)"),
			("not base64 at all", "this is not a key!!"),
			("base64 of 16 bytes", Data(repeating: 7, count: 16).base64EncodedString()),
			("base64 of 31 bytes", Data(repeating: 7, count: 31).base64EncodedString()),
			("base64 of 33 bytes", Data(repeating: 7, count: 33).base64EncodedString()),
			("whitespace only", "   ")
		]

		for (label, value) in cases {
			XCTAssertNil(
				SupportLogKeyCoding.publicKey(base64URLEncoded: value),
				"A key that is \(label) must disable the export, not produce a sealer."
			)
		}
	}

	func testPrivateKeyParsingFailsClosedToo() {
		XCTAssertNil(SupportLogKeyCoding.privateKey(base64URLEncoded: ""))
		XCTAssertNil(SupportLogKeyCoding.privateKey(base64URLEncoded: "nonsense"))
		XCTAssertNil(SupportLogKeyCoding.privateKey(
			base64URLEncoded: Data(repeating: 1, count: 16).base64EncodedString()
		))

		let key = Curve25519.KeyAgreement.PrivateKey()
		let encoded = SupportLogKeyCoding.base64URLEncoded(key.rawRepresentation)
		XCTAssertEqual(
			SupportLogKeyCoding.privateKey(base64URLEncoded: encoded)?.rawRepresentation,
			key.rawRepresentation
		)
	}

	/// The pair minted by `ProjectTool support-log keygen` has to work end to end, since that is
	/// the only way a real key is ever produced.
	func testAMintedPairSealsAndOpens() throws {
		let priv = Curve25519.KeyAgreement.PrivateKey()
		let publicText = SupportLogKeyCoding.base64URLEncoded(priv.publicKey.rawRepresentation)
		let privateText = SupportLogKeyCoding.base64URLEncoded(priv.rawRepresentation)

		let sealingKey = try XCTUnwrap(SupportLogKeyCoding.publicKey(base64URLEncoded: publicText))
		let openingKey = try XCTUnwrap(SupportLogKeyCoding.privateKey(base64URLEncoded: privateText))
		let log = Data("a line\n".utf8)

		let sealed = try SupportLogEnvelope.seal(
			log: log,
			metadata: SupportLogMetadata(app: "1", build: "1", date: "d", redacted: true),
			to: sealingKey,
			keyID: 1
		)

		XCTAssertEqual(try SupportLogEnvelope.open(sealed, with: openingKey).log, log)
	}
}
