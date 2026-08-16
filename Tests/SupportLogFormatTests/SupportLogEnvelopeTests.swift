//
//  SupportLogEnvelopeTests.swift
//  SupportLogFormatTests
//
//  AIA-0643.
//

import CryptoKit
import Foundation
import XCTest
@testable import SupportLogFormat

/// Tests for the sealed support-log container.
///
/// ## Why several of these look redundant
///
/// The obvious suite — round trip, "the marker is absent", "a bad key yields nil", "a tampered
/// header fails" — passes in full against an implementation that **compresses and never
/// encrypts**: emit `header ‖ 32 random bytes ‖ DEFLATE(payload)` and the round trip still works
/// (both ends share the constants), the marker is still absent (DEFLATE output contains no
/// literal), key parsing is untouched, and a flipped magic byte is still rejected — by the
/// *parser*, before any crypto runs.
///
/// The tests that mutation cannot survive are `testSealingTwiceProducesDifferentBytes` (DEFLATE is
/// deterministic, HPKE is not), `testADifferentPrivateKeyCannotOpen`, and the header-tamper test
/// below, which flips the **key id** — a byte the parser accepts and only the AEAD rejects.
final class SupportLogEnvelopeTests: XCTestCase {

	private let marker = "SECRET-MARKER-THAT-MUST-NOT-APPEAR-IN-CIPHERTEXT"

	private func makeMetadata(redacted: Bool = true) -> SupportLogMetadata {
		SupportLogMetadata(app: "1.0.7", build: "412", date: "2026-08-16T09:00:00Z", redacted: redacted)
	}

	private func makeLog(lines: Int = 400) -> Data {
		Data((0..<lines).map { "\($0)\t\(marker)\tsome log line\n" }.joined().utf8)
	}

	// MARK: - Round trip

	func testSealedLogRoundTripsByteIdentically() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let log = makeLog()
		let metadata = makeMetadata()

		let sealed = try SupportLogEnvelope.seal(
			log: log, metadata: metadata, to: recipient.publicKey, keyID: 1
		)
		let opened = try SupportLogEnvelope.open(sealed, with: recipient)

		XCTAssertEqual(opened.log, log, "The log must survive seal → open unchanged.")
		XCTAssertEqual(opened.metadata, metadata)
	}

	/// The delivered log is raw bytes and a crash mid-write can cut a record inside a multi-byte
	/// scalar, so any implementation that routes the payload through `String` loses exactly the
	/// crash report this feature exists to carry.
	func testAPayloadWithInvalidUTF8SurvivesUnchanged() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		// A lone continuation byte and a truncated three-byte sequence: both invalid UTF-8.
		var log = Data("first line\n".utf8)
		log.append(contentsOf: [0x80, 0xE2, 0x82])
		let sealed = try SupportLogEnvelope.seal(
			log: log, metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertEqual(try SupportLogEnvelope.open(sealed, with: recipient).log, log)
	}

	func testAnEmptyLogRoundTrips() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: Data(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertEqual(try SupportLogEnvelope.open(sealed, with: recipient).log, Data())
	}

	/// A log line that looks like the metadata must not confuse the positional split.
	func testALogLineThatLooksLikeMetadataDoesNotConfuseTheSplit() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let log = Data(#"{"app":"9.9.9","build":"1","date":"x","redacted":false}"# .utf8) + Data("\nreal line\n".utf8)
		let metadata = makeMetadata()

		let sealed = try SupportLogEnvelope.seal(
			log: log, metadata: metadata, to: recipient.publicKey, keyID: 1
		)
		let opened = try SupportLogEnvelope.open(sealed, with: recipient)

		XCTAssertEqual(opened.metadata, metadata, "The first line is the metadata, by position.")
		XCTAssertEqual(opened.log, log)
	}

	// MARK: - The mutations the obvious tests miss

	/// Kills the "compresses but never encrypts" implementation. DEFLATE is deterministic; HPKE
	/// mints a fresh ephemeral key per call, so two seals of identical input must differ.
	func testSealingTwiceProducesDifferentBytes() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let log = makeLog()

		let first = try SupportLogEnvelope.seal(
			log: log, metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		let second = try SupportLogEnvelope.seal(
			log: log, metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertNotEqual(first, second, "Identical input sealed twice must not produce identical bytes.")
		XCTAssertEqual(try SupportLogEnvelope.open(first, with: recipient).log, log)
		XCTAssertEqual(try SupportLogEnvelope.open(second, with: recipient).log, log)
	}

	func testADifferentPrivateKeyCannotOpen() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed, with: Curve25519.KeyAgreement.PrivateKey()))
	}

	func testTheLogNeverAppearsInTheSealedBytes() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertNil(sealed.range(of: Data(marker.utf8)), "Log content leaked into the sealed file.")
	}

	/// The redaction choice is the user's, and a file they hand to someone else must not announce
	/// it. It is sealed, not merely absent from the filename.
	func testTheRedactionFlagIsNotReadableWithoutTheKey() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(redacted: false), to: recipient.publicKey, keyID: 1
		)

		XCTAssertNil(sealed.range(of: Data("redacted".utf8)))
	}

	// MARK: - Tamper resistance

	/// Flips the **key id**, not the magic. The parser accepts any key id, so this reaches the
	/// AEAD — a magic-byte flip would be rejected before any crypto ran and would prove nothing
	/// about the seal.
	func testAFlippedKeyIDIsRejected() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		var sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		sealed[SupportLogEnvelope.magic.count + 1] = 9

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed, with: recipient))
	}

	func testAFlippedCiphertextByteIsRejected() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		var sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		sealed[sealed.count - 1] ^= 0xFF

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed, with: recipient))
	}

	func testTruncationIsRejected() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed.prefix(sealed.count - 1), with: recipient))
	}

	/// Every byte after the encapsulated key is handed to HPKE, so appended bytes fail the tag
	/// rather than being quietly ignored.
	func testAppendedBytesAreRejected() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed + Data([0x00]), with: recipient))
	}

	func testAFlippedEncapsulatedKeyIsRejected() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		var sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		sealed[SupportLogEnvelope.headerByteCount] ^= 0xFF

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed, with: recipient))
	}

	// MARK: - Parsing

	/// A `Data` slice keeps its parent's indices. An implementation using literal offsets without
	/// re-basing reads the wrong bytes while `count` still looks correct.
	func testASliceWithANonZeroStartIndexOpens() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let log = makeLog()
		let sealed = try SupportLogEnvelope.seal(
			log: log, metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		let offset = (Data([0xAA, 0xBB]) + sealed).dropFirst(2)
		XCTAssertNotEqual(offset.startIndex, 0, "Precondition: the slice must not be zero-based.")

		XCTAssertEqual(try SupportLogEnvelope.open(offset, with: recipient).log, log)
	}

	func testShortInputIsRejectedWithoutTrapping() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		for count in [0, 1, 8, 40, 55] {
			XCTAssertThrowsError(
				try SupportLogEnvelope.open(Data(repeating: 0, count: count), with: recipient),
				"A \(count)-byte input must throw, not trap."
			)
		}
	}

	func testForeignDataIsReportedAsNotASupportLog() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let foreign = Data(repeating: 0x41, count: 128)

		XCTAssertThrowsError(try SupportLogEnvelope.open(foreign, with: recipient)) { error in
			XCTAssertEqual(error as? SupportLogEnvelope.FormatError, .notASupportLog)
		}
	}

	func testAnUnknownFormatVersionIsRefusedBeforeAnyCrypto() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		var sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 1
		)
		sealed[SupportLogEnvelope.magic.count] = 99

		XCTAssertThrowsError(try SupportLogEnvelope.open(sealed, with: recipient)) { error in
			XCTAssertEqual(error as? SupportLogEnvelope.FormatError, .unsupportedVersion(99))
		}
	}

	/// After a rotation we hold several private keys and a wrong choice is indistinguishable from
	/// corruption, so the key id has to be readable without opening the file.
	func testTheKeyIDIsReadableWithoutThePrivateKey() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 7
		)

		XCTAssertEqual(try SupportLogEnvelope.keyID(of: sealed), 7)
	}

	// MARK: - Format constants
	//
	// Pinned deliberately. These bytes are the wire format; changing one is a breaking change that
	// must come with a new `formatVersion`, and a test failure here is the intended way to find out.

	func testTheWireFormatConstantsArePinned() {
		XCTAssertEqual(SupportLogEnvelope.magic, Data("AIALOG".utf8))
		XCTAssertEqual(SupportLogEnvelope.formatVersion, 1)
		XCTAssertEqual(SupportLogEnvelope.info, Data("AIALOG/1".utf8))
		XCTAssertEqual(SupportLogEnvelope.headerByteCount, 8)
		XCTAssertEqual(SupportLogEnvelope.keyByteCount, 32)
		XCTAssertEqual(SupportLogEnvelope.fileExtension, "aialog")
	}

	func testTheHeaderIsExactlyTheAdvertisedBytes() throws {
		let recipient = Curve25519.KeyAgreement.PrivateKey()
		let sealed = try SupportLogEnvelope.seal(
			log: makeLog(), metadata: makeMetadata(), to: recipient.publicKey, keyID: 3
		)

		XCTAssertEqual(sealed.prefix(6), Data("AIALOG".utf8))
		XCTAssertEqual(sealed[6], 1)
		XCTAssertEqual(sealed[7], 3)
		// header + encapsulated key + at least a tag.
		XCTAssertGreaterThan(sealed.count, 8 + 32 + 16)
	}

	// MARK: - Metadata

	func testMetadataEncodesToASingleLine() throws {
		let encoded = try makeMetadata().encodedLine()

		XCTAssertFalse(
			encoded.contains(0x0A),
			"""
			The metadata line must contain no newline. Adding `.prettyPrinted` to the encoder \
			would silently turn the envelope's positional split into a truncation.
			"""
		)
	}

	func testTimestampIsISO8601InUTC() {
		let instant = Date(timeIntervalSince1970: 1_776_000_000)

		let stamp = SupportLogMetadata.timestamp(for: instant)

		XCTAssertTrue(stamp.hasSuffix("Z"), "Expected a UTC timestamp, got \(stamp).")
		XCTAssertEqual(stamp.count, 20, "Expected yyyy-MM-ddTHH:mm:ssZ, got \(stamp).")
	}
}
