//
//  SharedFindingState.swift
//  AI Archeology
//
//  Holds the finding a shared link asked us to show, until a surface can show it (AIA-0650).
//

import Foundation

/// Owns the one thing a shared link produces: a finding to put on screen.
///
/// The app's root is a stack of gates — subscription, then analytics consent — and a link can
/// arrive at any point in it, including before any of them has resolved. So the payload is
/// *buffered* here and the presenting surface drains it when it is ready, rather than the URL
/// handler trying to present anything itself.
///
/// ## Held for the session, never quietly dropped
/// This deliberately does **not** copy ``MessageCenterState``'s notification-tap buffer, which
/// arms a timeout and discards the buffered id once a refreshed snapshot arrives without it. That
/// is right for a message id, which is a *reference* into content that may legitimately no longer
/// exist. A shared finding is not a reference — the payload is the content, complete and
/// self-describing, and nothing external has to resolve for it to be showable. Copying the
/// backstop would mean a link tapped by someone still behind the paywall is silently thrown away
/// while they subscribe, with no error and nothing to retry.
///
/// So a pending link survives until one of exactly two things happens: the user dismisses it, or a
/// newer link replaces it.
@MainActor
final class SharedFindingState: ObservableObject {

	/// The finding waiting to be shown, or `nil` when there is nothing pending.
	@Published private(set) var pending: FindingShareLink.Payload?

	/// Offers `url` to the shared-link route.
	///
	/// Returns whether it was ours. A scene-level `.onOpenURL` sees **every** URL the app is
	/// handed, and this app's custom scheme is registered for Clerk's OAuth callback — so the
	/// answer matters, and it is `FindingShareLink`'s strict host/path matching that decides it
	/// rather than anything here. A URL we do not recognise leaves `pending` untouched.
	@discardableResult
	func handle(_ url: URL) -> Bool {
		guard let payload = FindingShareLink.payload(from: url) else {
			// Deliberately not logged with the URL. Application-log entries become Sentry
			// breadcrumbs and on-disk support-log lines (AIA-0602), and a share link carries a
			// title, an author's name and coordinates in its fragment.
			LoggingPolicy.debug("Shared finding: ignoring a URL that is not a finding link", logger: .state)
			return false
		}
		// Newest wins. Two links in quick succession is a user tapping again, not a queue to work
		// through, and showing the older one would be showing the one they changed their mind about.
		pending = payload
		LoggingPolicy.info("Shared finding: buffered a link for presentation", logger: .state)
		return true
	}

	/// Clears the pending finding. Called only when the user dismisses it — never on a failed or
	/// deferred presentation attempt, which is what would lose the link.
	func dismiss() {
		guard pending != nil else { return }
		pending = nil
		LoggingPolicy.debug("Shared finding: dismissed by the user", logger: .state)
	}
}
