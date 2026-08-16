//
//  SupportLogEnvelope.swift
//  SupportLogFormat
//
//  The sealed support-log container (AIA-0643).
//

import Foundation
import CryptoKit

/// The one definition of the `.aialog` container — sealing, opening, and the byte layout.
///
/// **This type exists to be the single source of truth.** The app seals; `ProjectTool support-log
/// decrypt` opens; both compile *this* file. An earlier design duplicated the format on both sides
/// and policed it with a committed fixture, which is theatre: changing ``info`` on the app side
/// alone leaves the fixture test green (it still opens the frozen historical file) while every
/// real user's export becomes unopenable. `ios/AGENTS.md` §"Duplicated logic" requires the
/// extraction independently.
///
/// ## Layout
///
/// ```
/// "AIALOG"(6) | format version(1) | key id(1) | encapsulated key(32) | ciphertext+tag
/// ```
///
/// The 8-byte header is passed as AAD. The 32-byte encapsulated key that follows it is **not** in
/// the AAD, and does not need to be: it is an input to the key schedule, so altering it derives a
/// different secret and the tag fails regardless (``SupportLogEnvelopeTests`` proves this).
///
/// The rule for anyone extending the format is therefore about the header specifically: **any
/// cleartext field added to the header must also be added to the AAD**, because nothing else
/// authenticates those bytes.
///
/// ## What the seal does and does not prove
///
/// It proves an existing envelope has not been *modified*: the AEAD covers the payload and the
/// header, so a flipped byte anywhere fails to open.
///
/// It does **not** authenticate the sender. HPKE base mode has no sender key, so anyone who
/// extracts the public key from the app can mint a valid `.aialog` of their choosing. That is
/// accepted and outside the threat model — a user can already send us a fabricated report by
/// typing an email — but it has one consequence that must not be forgotten: **content recovered
/// from an envelope is untrusted input.** Do not describe the metadata as "tamper-proof" without
/// that qualification.
///
/// What the AAD buys, given that a wrong ``keyID`` already fails via the KEM (a different shared
/// secret) and an unknown ``formatVersion`` is refused before any crypto runs, is narrow but real:
/// **cross-version relabelling resistance.** Should a v2 ever share this layout while
/// reinterpreting the payload, AAD stops a v2 file relabelled as v1 from opening successfully into
/// authentic-looking, mis-inflated garbage.
public enum SupportLogEnvelope {

	// MARK: - Format constants
	//
	// Changing any value below changes the wire format. Because both the sealer and the opener
	// compile this file, a change is applied to both at once — which is the entire reason this
	// module exists. It is still a breaking change for files already in flight, so it requires a
	// new `formatVersion`, not an edit in place.

	/// File magic. Six bytes so the header is a round eight with the version and key id.
	public static let magic = Data("AIALOG".utf8)

	/// Bumped only when the layout or the payload interpretation changes.
	public static let formatVersion: UInt8 = 1

	/// HPKE key-schedule `info`. Pinned: a one-character disagreement between sealing and opening
	/// yields `CryptoKitError.authenticationFailure` with nothing pointing at the cause.
	public static let info = Data("AIALOG/1".utf8)

	/// X25519 + HKDF-SHA256 + ChaCha20-Poly1305.
	///
	/// CryptoKit ships **no** `Curve25519_SHA256_AES_GCM_256`; its AES-GCM presets are all
	/// NIST-curve. Take the preset rather than composing `Ciphersuite(kem:kdf:aead:)` by hand.
	public static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

	/// Suggested file extension. No UTI is declared for it: the file is opaque to everyone except
	/// us, so a system-wide type registration would buy nothing.
	public static let fileExtension = "aialog"

	/// Recommended MIME type for the mail attachment.
	public static let mimeType = "application/octet-stream"

	/// X25519 raw keys and the HPKE encapsulated key are all exactly this long.
	public static let keyByteCount = 32

	/// ChaCha20-Poly1305 authentication tag.
	private static let tagByteCount = 16

	/// magic + version + key id.
	public static let headerByteCount = 8

	/// The smallest byte count that could possibly be a valid envelope. Used to reject short input
	/// *before* slicing, because `Data` subscripting past the end traps rather than throwing.
	private static let minimumByteCount = headerByteCount + keyByteCount + tagByteCount

	/// Refuse to hand back more than this after inflating.
	///
	/// The honest scope: this bounds what we *process*, not what we allocate — `decompressed(using:)`
	/// sizes its own buffer, so a decompression bomb is still briefly resident. That is proportionate
	/// here (the opener runs on a developer Mac against files we chose to open, never in the app, and
	/// the app is the only thing that seals). The number is the delivered log bound of 5 MiB
	/// (`ApplicationLogBuffer.maximumByteCount`) plus generous headroom for the metadata line.
	public static let maximumInflatedByteCount = 8 * 1_024 * 1_024

	// MARK: - Errors

	public enum FormatError: Error, Equatable {
		/// Shorter than a header, an encapsulated key and a tag.
		case tooShort
		/// The leading bytes are not ``magic`` — not one of our files.
		case notASupportLog
		/// A version this build does not know how to interpret.
		case unsupportedVersion(UInt8)
		/// The metadata line was missing its `\n` terminator, or was not valid JSON.
		case malformedMetadata
		/// The inflated payload exceeded ``maximumInflatedByteCount``.
		case payloadTooLarge(Int)
		/// The metadata encoder emitted a newline, which would corrupt the positional split.
		case metadataContainsNewline
	}

	// MARK: - Sealing

	/// Seals `log` so only the holder of `recipient`'s private key can read it.
	///
	/// `metadata` travels **inside** the ciphertext, not beside it. It is deliberately not readable
	/// without the private key: `redacted` would otherwise announce the user's choice to anyone who
	/// sees the file, which is the same leak that keeps that word out of the filename. Everything a
	/// cleartext block would have carried for triage is either already in the mail body or is
	/// printed by `support-log decrypt`.
	///
	/// `log` is passed through byte-for-byte. It is never decoded as text: the unredacted path
	/// returns raw bytes and a crash mid-write can leave a record cut inside a multi-byte scalar,
	/// so a `String` round trip would fail on exactly the crash report this feature exists to carry.
	public static func seal(
		log: Data,
		metadata: SupportLogMetadata,
		to recipient: Curve25519.KeyAgreement.PublicKey,
		keyID: UInt8
	) throws -> Data {
		let metadataLine = try metadata.encodedLine()
		var payload = metadataLine
		payload.append(0x0A)
		payload.append(log)

		// Enforced on the way in as well as the way out. `open` refuses anything that inflates past
		// this bound, so without the same check here a caller with an oversized log would mint a
		// file that our own tool cannot read — a failure that would only surface once a user had
		// already sent it. Unreachable today (delivery is trimmed to 5 MiB) and cheap to keep true.
		guard payload.count <= maximumInflatedByteCount else {
			throw FormatError.payloadTooLarge(payload.count)
		}
		let header = self.header(keyID: keyID)
		let compressed = try (payload as NSData).compressed(using: .zlib) as Data
		// A fresh sender per call, never stored: `seal` is mutating and advances a sequence number,
		// so a reused sender would produce a second file the recipient cannot open.
		var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite, info: info)
		let ciphertext = try sender.seal(compressed, authenticating: header)
		return header + sender.encapsulatedKey + ciphertext
	}

	// MARK: - Opening

	/// Opens an envelope sealed to `recipient`.
	///
	/// Throws rather than returning `nil` so the caller can tell "not our file" from "wrong key"
	/// from "corrupt" — the three get very different responses when a support archive will not open.
	public static func open(
		_ envelope: Data,
		with recipient: Curve25519.KeyAgreement.PrivateKey
	) throws -> (metadata: SupportLogMetadata, log: Data) {
		// Copy to an array first. A `Data` produced by slicing keeps its parent's indices, so a
		// caller handing us `file.dropFirst(n)` would make every literal offset below wrong — and
		// wrong in the silent way, since the slice's `count` still looks right.
		let bytes = [UInt8](envelope)
		guard bytes.count >= minimumByteCount else { throw FormatError.tooShort }
		guard Data(bytes[0..<magic.count]) == magic else { throw FormatError.notASupportLog }
		let version = bytes[magic.count]
		guard version == formatVersion else { throw FormatError.unsupportedVersion(version) }

		let aad = Data(bytes[0..<headerByteCount])
		let encapsulatedEnd = headerByteCount + keyByteCount
		let encapsulatedKey = Data(bytes[headerByteCount..<encapsulatedEnd])
		// Every remaining byte goes to HPKE, so bytes appended to the file fail the tag rather
		// than being silently ignored.
		let ciphertext = Data(bytes[encapsulatedEnd...])

		var opener = try HPKE.Recipient(
			privateKey: recipient,
			ciphersuite: ciphersuite,
			info: info,
			encapsulatedKey: encapsulatedKey
		)
		let compressed = try opener.open(ciphertext, authenticating: aad)
		let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
		guard payload.count <= maximumInflatedByteCount else {
			throw FormatError.payloadTooLarge(payload.count)
		}
		return try split(payload: payload)
	}

	/// The key id an envelope was sealed under, without opening it.
	///
	/// This is the one piece of triage that genuinely must be readable in the clear: after a key
	/// rotation we hold several private keys, and picking the wrong one produces an
	/// indistinguishable authentication failure.
	public static func keyID(of envelope: Data) throws -> UInt8 {
		let bytes = [UInt8](envelope)
		guard bytes.count >= headerByteCount else { throw FormatError.tooShort }
		guard Data(bytes[0..<magic.count]) == magic else { throw FormatError.notASupportLog }
		return bytes[magic.count + 1]
	}

	// MARK: - Internals

	static func header(keyID: UInt8) -> Data {
		var header = magic
		header.append(formatVersion)
		header.append(keyID)
		return header
	}

	/// Splits the inflated payload at the **first newline byte**.
	///
	/// Positional and byte-level on purpose. Decoding the whole payload as UTF-8 to find the split
	/// would fail on a torn trailing record, and searching for a JSON-looking line would be
	/// defeated by a log line that happens to look like JSON.
	private static func split(payload: Data) throws -> (metadata: SupportLogMetadata, log: Data) {
		let bytes = [UInt8](payload)
		guard let newline = bytes.firstIndex(of: 0x0A) else { throw FormatError.malformedMetadata }
		let metadata = try SupportLogMetadata(encodedLine: Data(bytes[0..<newline]))
		return (metadata, Data(bytes[(newline + 1)...]))
	}
}
