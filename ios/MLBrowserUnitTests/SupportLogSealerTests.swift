//
//  SupportLogSealerTests.swift
//  MLBrowserUnitTests
//
//  AIA-0643.
//

import CryptoKit
import Foundation
import SupportLogFormat
import XCTest
@testable import ML_Browser

/// The app-side sealer.
///
/// The container itself is covered by `SupportLogFormatTests` (round trip, tamper resistance, and
/// the mutation tests that kill a compresses-but-never-encrypts implementation). What is asserted
/// here is the part that belongs to the app: that a bad key disables the export instead of
/// downgrading it, and that nothing in the file or its name leaks what the user chose.
final class SupportLogSealerTests: XCTestCase {

	private let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)

	private func makeSealer(
		_ recipient: Curve25519.KeyAgreement.PrivateKey,
		keyID: String = "1"
	) throws -> SupportLogSealer {
		let encoded = SupportLogKeyCoding.base64URLEncoded(recipient.publicKey.rawRepresentation)
		return try XCTUnwrap(SupportLogSealer(publicKeyBase64URL: encoded, keyID: keyID))
	}

	// MARK: - Sealing

	func testASealedLogOpensWithThePrivateKeyAndKeepsEveryByte() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealer = try makeSealer(recipient)
		let log = Data("2026-08-16 something broke\nhttps://example.com/page?token=secret\n".utf8)

		let sealed = try XCTUnwrap(sealer.seal(
			log: log, redacted: true, appVersion: "1.0.7", buildNumber: "412", date: referenceDate
		))
		let opened = try SupportLogEnvelope.open(sealed, with: recipient)

		XCTAssertEqual(opened.log, log)
		XCTAssertEqual(opened.metadata.app, "1.0.7")
		XCTAssertEqual(opened.metadata.build, "412")
		XCTAssertTrue(opened.metadata.redacted)
	}

	func testTheLogIsNotReadableInTheSealedBytes() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealer = try makeSealer(recipient)
		let secret = "https://example.com/page?token=secret"
		let log = Data(String(repeating: secret + "\n", count: 50).utf8)

		let sealed = try XCTUnwrap(sealer.seal(
			log: log, redacted: false, appVersion: "1.0.7", buildNumber: "412", date: referenceDate
		))

		XCTAssertNil(sealed.range(of: Data(secret.utf8)))
	}

	/// The redaction choice must not be recoverable from the file without the key — that is the
	/// whole reason it moved out of the filename and into the sealed payload.
	func testTheRedactionChoiceIsNotVisibleInTheSealedBytes() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealer = try makeSealer(recipient)

		let unredacted = try XCTUnwrap(sealer.seal(
			log: Data("x\n".utf8), redacted: false,
			appVersion: "1.0.7", buildNumber: "412", date: referenceDate
		))

		XCTAssertNil(unredacted.range(of: Data("redacted".utf8)))
		XCTAssertNil(unredacted.range(of: Data("unredacted".utf8)))
		XCTAssertFalse(try SupportLogEnvelope.open(unredacted, with: recipient).metadata.redacted)
	}

	func testTheKeyIDTravelsWithTheFileSoRotationCanBeUndone() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealer = try makeSealer(recipient, keyID: "7")

		let sealed = try XCTUnwrap(sealer.seal(
			log: Data("x\n".utf8), redacted: true,
			appVersion: "1", buildNumber: "1", date: referenceDate
		))

		XCTAssertEqual(try SupportLogEnvelope.keyID(of: sealed), 7)
	}

	func testAnEmptyLogStillSeals() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealer = try makeSealer(recipient)

		let sealed = try XCTUnwrap(sealer.seal(
			log: Data(), redacted: true, appVersion: "1", buildNumber: "1", date: referenceDate
		))

		XCTAssertEqual(try SupportLogEnvelope.open(sealed, with: recipient).log, Data())
	}

	// MARK: - Fail closed (criterion 6)

	/// Each of these is a real way a build can arrive without a usable key. Every one must produce
	/// **no sealer**, because the only alternative to sealing is exporting the log in the clear.
	func testEveryMalformedPublicKeyDisablesTheExport() {
		let cases: [(String, String?)] = [
			("absent from Info.plist", nil),
			("empty — an unset build setting substitutes to this", ""),
			("unsubstituted build-setting placeholder", "$(SUPPORT_LOG_PUBLIC_KEY)"),
			("not base64 at all", "definitely not a key"),
			("base64 of the wrong length", Data(repeating: 3, count: 16).base64EncodedString())
		]

		for (label, value) in cases {
			XCTAssertNil(
				SupportLogSealer(publicKeyBase64URL: value, keyID: "1"),
				"A public key that is \(label) must disable the export entirely."
			)
		}
	}

	func testAMalformedKeyIDDisablesTheExport() {
		let valid = SupportLogKeyCoding.base64URLEncoded(
			Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
		)

		for keyID in [nil, "", "0", "abc", "256", "-1", "1.5"] as [String?] {
			XCTAssertNil(
				SupportLogSealer(publicKeyBase64URL: valid, keyID: keyID),
				"Key id \(keyID.map { "\"\($0)\"" } ?? "nil") must disable the export."
			)
		}
	}

	func testAValidKeyAndKeyIDProduceASealer() {
		let valid = SupportLogKeyCoding.base64URLEncoded(
			Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
		)

		XCTAssertNotNil(SupportLogSealer(publicKeyBase64URL: valid, keyID: "1"))
		XCTAssertNotNil(SupportLogSealer(publicKeyBase64URL: valid, keyID: "255"))
		XCTAssertNotNil(SupportLogSealer(publicKeyBase64URL: valid, keyID: " 2 "))
	}

	// MARK: - Naming

	/// The old exports encoded the redaction state in the filename so a recipient could tell them
	/// apart. Now that the contents are sealed, such a name would be the only part of the file
	/// that still announces the user's choice.
	func testTheFileNameRevealsNothingAboutRedaction() {
		let name = SupportLogSealer.fileName(date: referenceDate)

		XCTAssertFalse(name.contains("unredacted"))
		XCTAssertFalse(name.contains("redacted"))
		XCTAssertTrue(name.hasSuffix(".aialog"), "Unexpected name: \(name)")
	}

	/// Colons are legal on APFS but are a path separator in enough of the places a support archive
	/// gets dragged through to be worth keeping out of a name we choose.
	func testTheFileNameHasNoColons() {
		XCTAssertFalse(SupportLogSealer.fileName(date: referenceDate).contains(":"))
	}

	func testTheFileNameIsStableForAGivenInstant() {
		XCTAssertEqual(
			SupportLogSealer.fileName(date: referenceDate),
			SupportLogSealer.fileName(date: referenceDate)
		)
	}

	func testTheAttachmentIsDeclaredAsOpaqueBytes() {
		XCTAssertEqual(SupportLogSealer.mimeType, "application/octet-stream")
	}
}
