//
//  SupportLogKeyCoding.swift
//  SupportLogFormat
//
//  How X25519 key material is written down (AIA-0643).
//

import Foundation
import CryptoKit

/// Encodes and decodes the key material that travels as text.
///
/// **base64url (RFC 4648 §5), unpadded.** Ordinary base64 contains `/`, and a random 32-byte key
/// therefore produces a `//` pair roughly one time in a hundred. `//` opens a comment in an
/// xcconfig, so an unlucky key would be silently truncated, decode to the wrong length, fail
/// closed, and disable the export — reproducibly, for that one key, forever. This repo has already
/// been bitten by `//` in injected values and escapes `://` by hand in
/// `ios/ci_scripts/ci_pre_xcodebuild.sh` because of it.
///
/// The public key now ships as an `Info.plist` literal rather than through an xcconfig, so that
/// specific path is closed anyway — but the alphabet costs nothing and the key material outlives
/// any one decision about where it is stored.
public enum SupportLogKeyCoding {

	/// base64url, unpadded.
	public static func base64URLEncoded(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	/// Decodes base64url, and tolerates ordinary base64 so a key pasted from another tool still
	/// works. Padding is optional.
	public static func decode(base64URLEncoded encoded: String) -> Data? {
		guard encoded.isEmpty == false else { return nil }
		var normalized = encoded
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		// Re-pad to a multiple of four; `Data(base64Encoded:)` rejects an unpadded string.
		let remainder = normalized.count % 4
		if remainder > 0 {
			normalized.append(String(repeating: "=", count: 4 - remainder))
		}
		return Data(base64Encoded: normalized)
	}

	/// The fail-closed public-key parse.
	///
	/// Returns `nil` — never a partially-trusted key — for every way a build can hand us a bad
	/// value: the key absent from `Info.plist`, an empty string (what an unset build setting
	/// substitutes to), a literal unsubstituted `$(…)` placeholder, text that is not base64, and
	/// base64 of the wrong length. Callers must treat `nil` as "no export", because the only
	/// alternative to sealing is shipping the log in the clear.
	public static func publicKey(base64URLEncoded encoded: String?) -> Curve25519.KeyAgreement.PublicKey? {
		guard let encoded,
			  let raw = decode(base64URLEncoded: encoded),
			  raw.count == SupportLogEnvelope.keyByteCount,
			  let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
		else { return nil }
		return key
	}

	/// The private-key counterpart, used only by the developer-side tool.
	public static func privateKey(base64URLEncoded encoded: String?) -> Curve25519.KeyAgreement.PrivateKey? {
		guard let encoded,
			  let raw = decode(base64URLEncoded: encoded),
			  raw.count == SupportLogEnvelope.keyByteCount,
			  let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
		else { return nil }
		return key
	}
}
