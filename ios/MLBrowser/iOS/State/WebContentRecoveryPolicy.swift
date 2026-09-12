//
//  WebContentRecoveryPolicy.swift
//  AI Archeology
//
//  AIA-0509: bounds automatic web-view recovery so a page that reliably wedges WebKit cannot
//  produce an infinite reload (or rebuild) loop.
//

import Foundation

/// Decides what automatic recovery, if any, the browser may attempt next.
///
/// Pure value type: no WebKit, no clock of its own — the caller passes `now`, so the ladder is
/// exhaustively unit-testable without waiting on real time.
struct WebContentRecoveryPolicy: Equatable {
	/// One rung of the escalation ladder. Each is attempted at most once per window.
	enum Recovery: Equatable {
		/// Cheapest rung: end-to-end revalidation of the current page.
		case reloadFromOrigin
		/// The web view itself is rebuilt. Recovers a wedged renderer or a poisoned cached
		/// document, which `reloadFromOrigin` cannot.
		case rebuild
	}

	/// How long a spent budget takes to replenish on its own.
	static let defaultWindow: TimeInterval = 60

	private let window: TimeInterval
	/// When the current window started; `nil` means nothing has been spent yet.
	private var windowStart: Date?
	private var usedReload = false
	private var usedRebuild = false
	private var usedRestore = false

	init(window: TimeInterval = defaultWindow) {
		self.window = window
	}

	/// The next rung to attempt, or `nil` when the ladder is exhausted for this window and the
	/// caller should surface the failure instead.
	///
	/// Consumes the rung it returns — two calls without an intervening reset never yield the same
	/// rung twice.
	mutating func nextRecovery(now: Date) -> Recovery? {
		expireWindowIfNeeded(now: now)
		if usedReload == false {
			beginWindowIfNeeded(now: now)
			usedReload = true
			return .reloadFromOrigin
		}
		if usedRebuild == false {
			beginWindowIfNeeded(now: now)
			usedRebuild = true
			return .rebuild
		}
		return nil
	}

	/// The rung a manual "Try Again" should perform.
	///
	/// User intent is never rate-limited: this resets the budget, and performs the *next* rung
	/// rather than replaying the weakest one — a user tapping retry on a page whose reload has
	/// already failed should not need two taps to reach the rung that might actually work.
	///
	/// "Next" keys off whether *any* rung has been spent, not whether the ladder is fully
	/// exhausted: after a failed reload the useful move is already `.rebuild`.
	mutating func manualRetry(now: Date) -> Recovery {
		let anyRungSpent = usedReload || usedRebuild
		reset()
		guard anyRungSpent else {
			usedReload = true
			windowStart = now
			return .reloadFromOrigin
		}
		usedRebuild = true
		windowStart = now
		return .rebuild
	}

	/// Claims the one session-state restore allowed per window, returning whether the caller may
	/// use it.
	///
	/// One strike: if the ladder is re-entered after a restore, the restored session is itself a
	/// suspect — it may be what re-wedges the renderer — so the next rebuild drops it and does a
	/// bare cache-busting load instead.
	///
	/// Tracked separately from `usedRebuild` rather than derived from it: `nextRecovery` marks the
	/// rebuild rung spent *before* the caller gets a chance to ask, so a derived flag would always
	/// read "already used" and the session would never be restored at all.
	mutating func consumeSessionRestore() -> Bool {
		guard usedRestore == false else { return false }
		usedRestore = true
		return true
	}

	/// Called when the user initiates a load. Their intent replenishes the budget — automatic
	/// recovery is bounded, deliberate navigation is not.
	mutating func userDidNavigate() {
		reset()
	}

	/// Deliberately NOT called from any navigation-delegate callback.
	///
	/// Resetting on `didFinish` would be self-defeating: the failure modes the rebuild rung exists
	/// for (a wedged renderer, a cached-but-dead document) *do* commit and *do* finish — that is
	/// their signature in the AIA-0509 log. A delegate-driven reset would therefore clear the
	/// budget after every failed recovery, so the ladder would never advance past its first rung
	/// and every subsequent callback would grant a fresh cycle.
	private mutating func reset() {
		windowStart = nil
		usedReload = false
		usedRebuild = false
		usedRestore = false
	}

	private mutating func expireWindowIfNeeded(now: Date) {
		guard let windowStart, now.timeIntervalSince(windowStart) >= window else { return }
		reset()
	}

	private mutating func beginWindowIfNeeded(now: Date) {
		guard windowStart == nil else { return }
		windowStart = now
	}
}
