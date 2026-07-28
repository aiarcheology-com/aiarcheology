//
//  AppAccountToken.swift
//  AI Archeology
//
//  Deterministic `appAccountToken` derivation, lifted out of the provider (AIA-0518).
//

import CryptoKit
import Foundation

/// Maps an account identifier onto the `appAccountToken` StoreKit attaches to a purchase, so a
/// future backend can reconcile a transaction to a user (AIA-0343).
///
/// Extracted from ``StoreKitSubscriptionProvider`` because the purchase path it sat on could not
/// be reached from a test: it read `Clerk.shared`, which traps when Clerk was never configured —
/// the state of every test process (AIA-0518).
enum AppAccountToken {

	/// The token for `accountIdentifier`, or `nil` when there is no account (signed out, or
	/// Clerk not configured). A `nil` token means the purchase simply carries no account tag.
	///
	/// Uses SHA-256 rather than `Hasher`, whose seed is randomized per process run: `Hasher`
	/// would yield a different token on every launch and defeat the reconciliation entirely.
	/// Clerk user ids are not UUIDs, hence the fold into one.
	static func make(from accountIdentifier: String?) -> UUID? {
		guard let accountIdentifier else { return nil }
		let digest = Array(SHA256.hash(data: Data(accountIdentifier.utf8)).prefix(16))
		return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
						   digest[4], digest[5], digest[6], digest[7],
						   digest[8], digest[9], digest[10], digest[11],
						   digest[12], digest[13], digest[14], digest[15]))
	}
}
