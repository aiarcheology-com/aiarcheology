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

	/// What a shared link resolved to.
	///
	/// The two cases exist because "this URL is not ours" and "this URL **is** ours and we could not
	/// read it" demand opposite responses, and collapsing them is a user-visible bug rather than a
	/// tidiness question.
	///
	/// A link that reaches the app has already been matched by the association file, so iOS opened
	/// this app *instead of* the web page — and the web page is where the "this link was shortened or
	/// edited" explanation lives. On exactly the devices that have the app installed, that
	/// explanation can never run. If the app then does nothing, the user has tapped a link, watched
	/// an app open, and been left on whatever screen happened to be showing. That is the blank screen
	/// this ticket's fourth acceptance criterion forbids, so the app has to say it itself.
	enum Pending: Equatable {
		/// A link that parsed. The finding to show.
		case finding(FindingShareLink.Payload)
		/// Ours by host and path, but the payload would not parse — truncated in transit by a
		/// platform that shortened it, hand-edited, or written by a newer version of the app.
		case unreadable
	}

	/// What is waiting to be shown, or `nil` when there is nothing pending.
	@Published private(set) var pending: Pending?

	/// The stored finding the pending link resolved to — either one this device already had, or the
	/// row the import just wrote. Nil until that is settled (AIA-0835).
	@Published private(set) var storedId: UUID?

	/// Set when the import threw. The card still renders and still has its way out; this is what
	/// stops a failure looking like a success.
	@Published private(set) var importFailed = false

	/// The payload the import has already run for.
	///
	/// This is the idempotency key, and it lives HERE rather than in the view because the view's
	/// `@State` dies with the overlay: a backgrounded app, a size-class change or a second
	/// `onAppear` would otherwise import the same link again. For a link carrying an id that would
	/// be harmless -- ``FindingRepository/saveReceived(_:)`` returns the existing row -- but an
	/// id-less link mints a fresh UUID each time, so without this a re-appear would silently
	/// duplicate it.
	private var importedPayload: FindingShareLink.Payload?

	/// Offers `url` to the shared-link route.
	///
	/// Returns whether it was ours. A scene-level `.onOpenURL` sees **every** URL the app is
	/// handed, and this app's custom scheme is registered for Clerk's OAuth callback — so the
	/// answer matters, and it is `FindingShareLink`'s strict host/path matching that decides it
	/// rather than anything here. A URL we do not recognise leaves `pending` untouched.
	@discardableResult
	func handle(_ url: URL) -> Bool {
		// Matching and parsing are asked separately, on purpose. `matches` answers "is this ours",
		// `payload(from:)` answers "can we read it" — and only the first may cause this to decline
		// the URL, because declining is what lets Clerk's OAuth callback through untouched.
		guard FindingShareLink.matches(url) else {
			// Deliberately not logged with the URL. Application-log entries become Sentry
			// breadcrumbs and on-disk support-log lines (AIA-0602), and a share link carries a
			// title, an author's name and coordinates in its fragment.
			LoggingPolicy.debug("Shared finding: ignoring a URL that is not a finding link", logger: .state)
			return false
		}
		// Newest wins. Two links in quick succession is a user tapping again, not a queue to work
		// through, and showing the older one would be showing the one they changed their mind about.
		if let payload = FindingShareLink.payload(from: url) {
			// The SAME link again is not a new link. Resetting here would drop `storedId` while
			// `pending` stays equal -- so `onChange` never fires, the re-store is refused as a
			// duplicate, and the editor vanishes with nothing able to bring it back.
			if pending == .finding(payload) {
				LoggingPolicy.debug("Shared finding: the same link again; keeping what is on screen", logger: .state)
				return true
			}
			// Newest wins, so the previous link's resolution must not survive into this one.
			storedId = nil
			importFailed = false
			importedPayload = nil
			pending = .finding(payload)
			LoggingPolicy.info("Shared finding: buffered a link for presentation", logger: .state)
		} else {
			// Reset here too. Clearing only on the readable branch meant an unreadable link kept the
			// PREVIOUS link's stored row, and the host prefers a stored finding over the error — so
			// tapping a truncated link reopened the last finding instead of saying it was unreadable.
			storedId = nil
			importFailed = false
			importedPayload = nil
			pending = .unreadable
			LoggingPolicy.warning("Shared finding: link matched but its payload could not be read", logger: .state)
		}
		return true
	}

	/// Stores the pending link's finding, at most once per link.
	///
	/// Called by the presenting host rather than from ``handle(_:)``, and that separation is
	/// load-bearing: a URL can arrive before the store is open — `AppState` is only ready after
	/// `awaitStoreReady()` — so buffering and writing must not happen at the same moment. The host
	/// is gated on `isReady`, so by the time this runs there is a store to write to.
	///
	/// A finding the device already has is never rewritten: the lookup inside `saveReceived` returns
	/// it untouched, which is what keeps the sender's copy authoritative.
	func storePendingFinding(using repository: FindingRepository) {
		guard case .finding(let payload) = pending else { return }
		guard importedPayload != payload else { return }
		do {
			storedId = try repository.saveReceived(payload).entityId
			importFailed = false
			// Recorded only on SUCCESS. Marking the attempt up front would suppress every retry of a
			// link that failed to store, leaving the user on a card that silently saved nothing.
			importedPayload = payload
		} catch {
			// Deliberately not logged with the payload: application-log entries become Sentry
			// breadcrumbs and on-disk support-log lines (AIA-0602), and a link carries a title, an
			// author's name and coordinates.
			LoggingPolicy.error("Shared finding: could not store the received finding", error: error, logger: .state)
			importFailed = true
		}
	}

	/// Clears the pending finding. Called only when the user dismisses it — never on a failed or
	/// deferred presentation attempt, which is what would lose the link.
	func dismiss() {
		guard pending != nil else { return }
		pending = nil
		storedId = nil
		importFailed = false
		importedPayload = nil
		LoggingPolicy.debug("Shared finding: dismissed by the user", logger: .state)
	}
}
