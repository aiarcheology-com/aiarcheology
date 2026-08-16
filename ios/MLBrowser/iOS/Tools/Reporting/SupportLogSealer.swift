//
//  SupportLogSealer.swift
//  AI Archeology
//
//  Seals the exported application log so only support can read it (AIA-0643).
//

import Foundation
import CryptoKit
import SupportLogFormat

/// Turns a application-log snapshot into the single sealed file the user can send.
///
/// The public key is **injected**, never read from the bundle by this type. That is what makes
/// "the bytes are sealed" assertable: a test constructs a sealer around a key it minted and reads
/// the output. It is the same argument ``SupportRequest`` makes for being a pure value type — this
/// type decides what leaves the device, so the only honest way to claim it sends X and not Y is a
/// test that reads the output. ``bundled`` is the one place that touches `Bundle.main`.
///
/// ## Fail closed
///
/// Every constructor and every method returns `nil` rather than falling back. This is a
/// **deliberate divergence from the convention right next door**: `SentryCrashReportingService`
/// treats a missing key as "feature off" and carries on (`:75-79`), which is correct for crash
/// reporting and catastrophic here. The fallback for "cannot seal" is not "send nothing useful",
/// it is "send the log in the clear" — the exact thing this type exists to prevent. A build with
/// no key must therefore offer no log export at all.
struct SupportLogSealer: Sendable {

	private let publicKey: Curve25519.KeyAgreement.PublicKey
	private let keyID: UInt8

	/// Fails when the key is absent, empty, an unsubstituted build-setting placeholder, not
	/// base64url, or not 32 bytes. Callers must treat `nil` as "no export".
	init?(publicKeyBase64URL: String?, keyID: String?) {
		guard let publicKey = SupportLogKeyCoding.publicKey(base64URLEncoded: publicKeyBase64URL),
			  let keyIDText = keyID?.trimmingCharacters(in: .whitespacesAndNewlines),
			  let parsedKeyID = UInt8(keyIDText),
			  parsedKeyID > 0
		else { return nil }
		self.publicKey = publicKey
		self.keyID = parsedKeyID
	}

	/// The sealer this build ships with, or `nil` when the key is missing or malformed.
	///
	/// `nil` is routine, not exceptional: it is what a checkout without a configured key produces,
	/// and the support form simply offers no log in that case. Resolved once — the parse is pure
	/// and the plist cannot change while the app runs.
	static let bundled: SupportLogSealer? = SupportLogSealer(
		publicKeyBase64URL: Bundle.main.object(forInfoDictionaryKey: publicKeyInfoDictionaryKey) as? String,
		keyID: Bundle.main.object(forInfoDictionaryKey: keyIDInfoDictionaryKey) as? String
	)

	static let publicKeyInfoDictionaryKey = "SupportLogPublicKey"
	static let keyIDInfoDictionaryKey = "SupportLogKeyID"

	/// Seals `log` and returns the bytes to attach, or `nil` if anything at all went wrong.
	///
	/// **There is no partial success and no plain-text fallback.** A compression failure, an HPKE
	/// failure, a metadata-encoding failure — each returns `nil` and the caller attaches nothing.
	/// The code this replaced argued the opposite twice ("none of those is a reason to send
	/// nothing", "a bulky attachment beats a missing one"); that instinct is correct for a
	/// *format* choice and wrong for an *encryption* one, and both comments were deleted rather
	/// than adapted so the next reader does not inherit them.
	func seal(
		log: Data,
		redacted: Bool,
		appVersion: String,
		buildNumber: String,
		date: Date
	) -> Data? {
		let metadata = SupportLogMetadata(
			app: appVersion,
			build: buildNumber,
			date: SupportLogMetadata.timestamp(for: date),
			redacted: redacted
		)
		do {
			return try SupportLogEnvelope.seal(
				log: log,
				metadata: metadata,
				to: publicKey,
				keyID: keyID
			)
		} catch {
			// `.debug`, not `.error`: `error` spends Sentry event quota via captureError and
			// AIA-0602 requires production Sentry volume to be unchanged. The user sees the
			// outcome directly — no attachment, and a form that says so.
			LoggingPolicy.debug(
				"Could not seal the application log (\(error.localizedDescription)) — attaching nothing",
				logger: .ui
			)
			return nil
		}
	}

	/// The name the sealed file carries.
	///
	/// Deliberately says nothing about redaction. The old names encoded it
	/// (`…-log-unredacted.txt`) so a recipient could tell the two apart by reading the filename —
	/// which, now that the contents are sealed, would be the only thing in the whole file that
	/// leaks the user's choice to anyone who sees it in Files, Messages or AirDrop. The flag is
	/// recorded inside the envelope instead, where it is sealed and covered by the AEAD.
	///
	/// The timestamp uses no colons: they are legal on APFS but are a path separator in enough
	/// places (and in enough of the tools a support archive gets dragged through) to be worth
	/// avoiding in a name we choose.
	static func fileName(date: Date) -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.locale = Locale(identifier: "en_US_POSIX")
		return "mlbrowser-log-\(formatter.string(from: date)).\(SupportLogEnvelope.fileExtension)"
	}

	/// The MIME type for the mail attachment: opaque bytes, which is what they are.
	static var mimeType: String { SupportLogEnvelope.mimeType }
}
