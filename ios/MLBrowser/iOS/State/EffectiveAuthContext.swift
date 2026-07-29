//
//  EffectiveAuthContext.swift
//  AI Archeology
//
//  The consent/attribution identity (AIA-0536).
//

import Foundation

/// What the app may attribute analytics to right now, derived from ``AuthState``.
///
/// This is the **consent/attribution** identity and nothing else. Two nearby identities
/// deliberately do *not* consume it, because for them resolving to anonymous is the destructive
/// direction rather than the safe one:
///
/// - ``MessageCenterState``'s persistence realm (`userID ?? "anon"`) keys the stored
///   seen/dismissed/replied sets. Driving it from this type would resolve every cold launch to the
///   anonymous realm for the length of the validation round-trip — resurfacing dismissed messages
///   and writing dismissals the account will never read back. It keeps its own hydrated Clerk read.
/// - ``ClerkMessageReplyWriter`` needs the Clerk `User` object to write metadata, not an
///   identifier. It is a write surface, not an identity source.
///
/// What earns this type its existence: ``AuthState/accountIdentifier`` collapses "signed out" and
/// "not resolved yet" into the same `nil`. Analytics consent has to tell them apart, because the
/// first is a scope that can be asked a consent question and answer it, and the second is not.
enum EffectiveAuthContext: Equatable {
	/// Nothing is resolved yet, or an account switch is in flight. **Not** a scope: nothing may be
	/// attributed and no consent question may be asked.
	///
	/// Covers two situations that must behave identically. At launch, the gate has not resolved. And
	/// during an out-of-band account switch ``AuthState`` clears the outgoing account *before* it
	/// suspends, precisely so that nothing tracked during the validation round-trip is attributed to
	/// a user who is no longer signed in — that window is `(.ready, nil)`, and it lands here.
	case indeterminate

	/// No session. A real scope: an anonymous user can be asked for consent, and is attributed to
	/// the transport's own anonymous installation identity.
	case anonymous

	/// A freshly server-validated account.
	case validated(String)

	/// A session existed but could not be verified — the device is offline.
	///
	/// The payload is `nil` in the **common** case rather than the rare one: on a cold offline
	/// launch the published identifier has not been set when validation fails, so there is nothing
	/// to retain. A non-`nil` payload means the process had already reached ``validated(_:)`` and
	/// later lost connectivity.
	///
	/// Consumers must treat this as *no transition happened*, not as a state to act on. Losing
	/// connectivity is not a change of account, and acting on it would tear down an already-consented
	/// transport on every offline foreground — whose re-activation re-emits the transport's
	/// automatic session signal.
	case suspended(String?)
}

extension EffectiveAuthContext {
	/// Whether anything downstream should react to this context at all.
	///
	/// The rule stated once, because two places need it — ``AnalyticsState/updateAuthContext(_:)``
	/// and ``AccountAnalyticsCoordinator`` — and a rule spelled out twice is a rule that can rot in
	/// one copy without any test noticing. (It did: an earlier draft switched on the cases in both,
	/// which made the analytics branch unreachable from the coordinator and left a mutation to it
	/// undetected by every test in the suite.)
	///
	/// The invariant it encodes: **a transition corresponds to a write of
	/// ``AuthState/accountIdentifier``.** ``suspended(_:)`` is the sole context produced without
	/// such a write, because the offline path deliberately leaves the published identity alone —
	/// losing connectivity is not a change of account.
	var isAttributionTransition: Bool {
		if case .suspended = self { return false }
		return true
	}

	/// The account this context attributes to. `nil` for every scope that has no account, which
	/// includes both ``anonymous`` (nobody) and ``indeterminate`` (not known yet) — they differ in
	/// whether consent may be *asked*, not in who is attributed.
	///
	/// Meaningless unless ``isAttributionTransition`` is `true`; callers must check that first.
	var attributedAccount: String? {
		if case let .validated(account) = self { return account }
		return nil
	}
}
