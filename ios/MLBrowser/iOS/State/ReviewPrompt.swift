//
//  ReviewPrompt.swift
//  AI Archeology
//
//  Native App Store rating request after a positive moment (AIA-0117).
//

import Foundation

/// Decides whether the app may *ask* for a review. Pure and clock-injected, so the entire policy is
/// unit-testable; nothing here touches StoreKit, SwiftUI, or persistence.
///
/// ## Why the interval is 122 days
///
/// Apple caps the *display* of the review sheet at three times per user per app per 365 days, and
/// `requestReview` reports nothing back — the app can never learn whether a given request actually
/// showed anything. So this policy governs our **requests**, and deliberately budgets them to the
/// same ceiling: a minimum gap of `ceil(365 / 3) = 122` days admits at most three requests in any
/// 365-day window. A shorter gap (90 days admits five) would spend requests after Apple has already
/// stopped showing the sheet, which is invisible and therefore undiagnosable.
enum ReviewPromptPolicy {
	/// Positive moments required before the first request. The very first saved finding is the
	/// weakest possible signal — the user has not yet chosen to do the thing twice.
	static let requiredEventCount = 3

	/// `ceil(365 / 3)` days. See the type comment for why this exact number.
	static let minimumRequestInterval: TimeInterval = 122 * 24 * 60 * 60

	/// - Parameters:
	///   - eventCount: qualifying moments accumulated since the last request.
	///   - lastRequestDate: when the app last asked, or `nil` if it never has.
	///   - now: injected clock.
	static func shouldRequest(eventCount: Int, lastRequestDate: Date?, now: Date) -> Bool {
		guard eventCount >= requiredEventCount else { return false }
		guard let lastRequestDate else { return true }
		// A negative interval (the clock moved backwards) is rejected on purpose: reading a
		// backwards clock as "very long ago" would let a date change unlock an immediate re-ask.
		// `ReviewPromptCoordinator` clamps a future stored date so this cannot suppress forever.
		return now.timeIntervalSince(lastRequestDate) >= minimumRequestInterval
	}
}

/// Which flow produced a winning moment. A moment can only be consumed by the flow that recorded
/// it, so a dismissal belonging to a *different* flow cannot spend it — the case that matters in
/// practice, since an ordinary configuration sheet closes far more often than an import completes.
///
/// The scope is per-flow, **not** per-window. `AppState`, and so this coordinator, is shared by
/// every window of the `WindowGroup`, so two windows running the *same* flow still share one
/// pending moment: if window A saves a finding and window B then cancels its own save sheet, B's
/// dismissal consumes A's moment and the prompt appears in B. Only placement is wrong — the policy
/// still caps how often a request can be spent. Making the per-window claim true would require
/// keying the pending moment to a per-presentation token, which is not worth the plumbing for a
/// correctly-earned prompt surfacing in a sibling window.
enum ReviewPromptSource {
	case findingSaved
	case modelImported
}

/// Records winning moments and decides when the app may ask for a review.
///
/// Deliberately **not** an `ObservableObject`: nothing renders from it. It follows the
/// `FindingRepository` precedent (AIA-0392) — a plain type passed by initializer — and imports
/// neither SwiftUI nor StoreKit. The view layer owns the `@Environment(\.requestReview)` call,
/// which keeps this type free of the Harmonize boundary baseline that fails a new state type
/// importing SwiftUI, and avoids a published token that every window in a `WindowGroup` would
/// observe (and each fire its own request from).
///
/// ## Record now, ask on dismissal
///
/// Both winning moments happen *inside a sheet* — the finding-save sheet, the model-import sheet.
/// Asking there would stack the system review sheet on top of a sheet that is already dismissing.
/// So the moment is recorded where it happens and consumed by the presenter's `onDismiss`, with no
/// timers (AGENTS.md §15).
@MainActor
final class ReviewPromptCoordinator {
	private let settings: Settings
	private let featureFlags: FeatureFlagsState
	/// Environments where the system sheet cannot or must not appear: unit tests, UI tests,
	/// SwiftUI previews, and TestFlight-like distribution (Apple does not display the review
	/// prompt in TestFlight builds, so a request there would be spent for nothing).
	private let isSuppressedEnvironment: Bool
	private let now: () -> Date

	/// The flow whose winning moment is waiting for its sheet to close, or `nil` when none is.
	/// In memory only: a moment that does not survive to its dismissal is not one the user finished.
	private var pendingMoment: ReviewPromptSource?

	init(
		settings: Settings,
		featureFlags: FeatureFlagsState,
		isSuppressedEnvironment: Bool,
		now: @escaping () -> Date = Date.init
	) {
		self.settings = settings
		self.featureFlags = featureFlags
		self.isSuppressedEnvironment = isSuppressedEnvironment
		self.now = now
	}

	/// A winning moment completed: a finding was saved, or a model was imported/converted.
	///
	/// Counted unconditionally — including while the flag is off or the environment is suppressed —
	/// so a TestFlight tester, or anyone who used the app while the flag was off, does not start
	/// from zero afterwards. Deciding whether to *ask* is `consumePendingRequest`'s job.
	///
	/// Callers must record **before** the hosting sheet begins dismissing, so the pending moment is
	/// always consumed by that sheet's own `onDismiss` and never by an unrelated later one.
	func recordPositiveMoment(_ source: ReviewPromptSource) {
		settings.ratingPromptEventCount += 1
		pendingMoment = source
	}

	/// Call from the `onDismiss` of the sheet that hosted the moment.
	///
	/// - Returns: `true` exactly when the caller should invoke `requestReview()`. Returning `true`
	///   is what "spends" a request: it stamps the date and zeroes the count. Every suppressed or
	///   ineligible path returns `false` and leaves the count intact, so the moment is never lost.
	func consumePendingRequest(_ source: ReviewPromptSource, isTourActive: Bool) -> Bool {
		// Only the flow that recorded the moment may spend it — see ``ReviewPromptSource`` for what
		// this does and does not guarantee across windows.
		guard pendingMoment == source else { return false }
		// Cleared before every eligibility guard below on purpose: an ineligible consume must still
		// end the moment, or it would linger and fire on some later, unrelated dismissal.
		pendingMoment = nil

		guard featureFlags.snapshot.isRatingPromptEnabled else { return false }
		guard isSuppressedEnvironment == false else { return false }
		// Mid-tour the user is following instructions, not admiring their own result (AIA-0333).
		guard isTourActive == false else { return false }

		// One instant for both the decision and the stamp, so they cannot disagree.
		let requestDate = now()
		// A stored date in the future means the clock was ahead when a request was spent and has
		// since been corrected. Left alone it would suppress the prompt until that date plus the
		// interval — potentially years. Clamping restarts the cooldown from now.
		if let last = settings.ratingPromptLastRequestDate, last > requestDate {
			settings.ratingPromptLastRequestDate = requestDate
		}

		guard ReviewPromptPolicy.shouldRequest(
			eventCount: settings.ratingPromptEventCount,
			lastRequestDate: settings.ratingPromptLastRequestDate,
			now: requestDate
		) else { return false }

		settings.ratingPromptLastRequestDate = requestDate
		settings.ratingPromptEventCount = 0
		return true
	}
}
