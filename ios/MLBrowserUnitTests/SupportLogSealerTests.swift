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

	/// Checks the word, not the entropy: this catches the realistic regression (metadata moving
	/// back outside the ciphertext), and the real guarantee is that the flag is inside the AEAD.
	func testTheWordRedactedDoesNotAppearInTheSealedBytes() throws {
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

	// MARK: - The key this build actually ships

	/// Everything above injects a key the test minted, which is what makes the sealing claims
	/// assertable — and also means none of it would notice if the **real** key were missing,
	/// misspelled in `Info.plist`, or mangled on its way into the bundle. That is the one link the
	/// rest of the suite cannot see, and it fails silently: the log section simply disappears, and
	/// a passing test run says nothing about it.
	///
	/// Scope, precisely: this proves the shipped key *resolves and works*. It does **not** police
	/// how it is declared — a duplicate entry would resolve fine here, because Apple's parser keeps
	/// the last occurrence. That case is caught by
	/// `ArchitectureTests.testSupportLogKeysAreDeclaredExactlyOnce`, which reads the source plist.
	func testTheBundledKeyIsPresentAndUsable() throws {
		let bundled = try XCTUnwrap(
			SupportLogSealer.bundled,
			"""
			No usable SupportLogPublicKey in Info.plist. The app builds and every other test passes, \
			but the log export is switched off entirely in this build — check the key and key id.
			"""
		)

		let sealed = try XCTUnwrap(bundled.seal(
			log: Data("a line\n".utf8),
			redacted: true,
			appVersion: "1.0.7",
			buildNumber: "412",
			date: referenceDate
		))

		// We cannot open it — the app holds no private key, which is the point. What is assertable
		// is that the shipped key produced a well-formed envelope carrying the shipped key id.
		XCTAssertEqual(sealed.prefix(SupportLogEnvelope.magic.count), SupportLogEnvelope.magic)
		// Unwrapped first so a malformed SupportLogKeyID reports itself, rather than surfacing as
		// the far less obvious "1 is not equal to nil" from the comparison below.
		let advertisedKeyID = try XCTUnwrap(
			UInt8(Bundle.main.object(
				forInfoDictionaryKey: SupportLogSealer.keyIDInfoDictionaryKey
			) as? String ?? ""),
			"SupportLogKeyID is missing from Info.plist or is not a number in 1...255."
		)
		XCTAssertEqual(
			try SupportLogEnvelope.keyID(of: sealed), advertisedKeyID,
			"The sealed file must carry the key id this build advertises, or rotation cannot work."
		)
		XCTAssertNil(sealed.range(of: Data("a line".utf8)))
	}
}
