//
//  FreeAccessWindow.swift
//  AI Archeology
//
//  The app-managed free-access period that precedes the StoreKit paywall (AIA-0556).
//

import Foundation

/// How long a granted window lasts, and when it reminds.
///
/// Passed to a grant and frozen into the resulting record — never read again while a window is
/// open. That is the whole point of the type: shortening `grantDays` from 14 to 7 must not wall
/// every mid-window user the moment the new value lands, and lengthening it must not silently
/// hand them days they were never granted. Both are decisions about *new* windows only.
struct FreeAccessThresholds: Equatable, Sendable {
	/// Calendar days of free access, counted from the grant day.
	let grantDays: Int

	/// The day on which the "your free access is running out" reminder becomes due.
	let reminderOnDay: Int

	/// The shipped window: 14 days, reminding on day 7.
	static let standard = FreeAccessThresholds(grantDays: 14, reminderOnDay: 7)
}

/// What the free-access window is doing at a given instant.
enum FreeAccessPhase: Equatable, Sendable {
	/// No window is open. Also reported while the stores are still being reconciled, which is why
	/// this must never be read as permission to grant — see ``FreeAccessWindow/canGrant``.
	case notGranted

	/// A window is open. `remaining` is whole calendar days left and is always at least 1: the
	/// day it would reach 0 is the day the window is `.expired`.
	case active(remaining: Int)

	/// A window is open, the reminder day has arrived, and the reminder has not been shown yet.
	case reminderDue(remaining: Int)

	/// The window has run out.
	case expired
}

/// The 14-day app-managed free-access period, as a pure value (AIA-0556).
///
/// A `struct`, not an `ObservableObject`: this mirrors the ``FeatureFlagSnapshot`` /
/// ``FeatureFlagsState`` split, so the whole state machine is testable without the composition
/// root and the observable owner stays a thin wrapper. Nothing here reads a clock, a flag or a
/// store — every transition takes the instant it happens at, and ``FreeAccessAnchorService`` owns
/// the injected clock so no view or caller ever needs a raw `Date`.
///
/// ## Day counting
///
/// Days are **calendar days since the grant day** — not elapsed 24-hour periods, and not
/// days-on-which-the-app-ran. A user granted a window on Monday evening keeps the rest of Monday
/// plus 13 further days, which is what "14 days" means to the person reading it. The arithmetic
/// uses the injected `calendar`; production passes `Calendar.current`, so the boundary moves at
/// the user's own midnight in their own time zone.
///
/// Across a daylight-saving transition the window neither shortens nor lengthens. `expiresAt` is
/// computed once, at grant, with `Calendar.date(byAdding: .day,)`, which advances a whole calendar
/// day even when that day is 23 or 25 hours long; the resulting instant is then frozen. A later
/// time-zone change moves only where `startOfDay` falls when counting the days *remaining* — it
/// can never move the expiry itself, because that is already an absolute instant.
///
/// ## Reconciliation before granting
///
/// A window starts in ``Anchor/reconciling``, where ``canGrant`` is `false`. Both the fast
/// (UserDefaults) and durable (Keychain) stores must be read and folded in by ``settle(fast:durable:)``
/// before any grant decision exists. Skipping that ordering is not a cosmetic bug: the app would
/// see "not granted", grant, and write a brand-new anchor over a Keychain copy nobody had looked
/// at yet — so delete-and-reinstall would farm a fresh 14 days despite the mirror existing.
struct FreeAccessWindow: Equatable, Sendable {

	/// The persisted anchor: everything a resumed install needs in order to honour a window it
	/// did not itself grant.
	struct Record: Codable, Equatable, Sendable {
		/// When the window was granted — the identity of the anchor. Reconciliation picks the
		/// *earliest* of these, so it is the one field that is never rewritten.
		let grantedAt: Date

		/// First instant at which free access is over. Frozen at grant (see ``FreeAccessThresholds``).
		let expiresAt: Date

		/// First instant at which the reminder is due. Frozen at grant.
		let reminderDueAt: Date

		/// The latest instant this record has ever been shown — the floor that a device clock
		/// rolled backwards is clamped to.
		var maxObservedDate: Date

		/// Whether the reminder has already been surfaced, so it is shown once per window.
		var reminderShown: Bool
	}

	/// How much the app knows about the anchor. This *is* the reconciliation gate.
	enum Anchor: Equatable, Sendable {
		/// The two stores have not both been read yet. **Granting is forbidden here.**
		case reconciling

		/// Both stores were read and neither held an anchor.
		case absent

		/// Both stores were read; this is the earliest anchor either of them held.
		case granted(Record)
	}

	private(set) var anchor: Anchor

	/// The calendar every day computation goes through. See the type comment for the time-zone
	/// and DST contract.
	private let calendar: Calendar

	init(anchor: Anchor = .reconciling, calendar: Calendar = .current) {
		self.anchor = anchor
		self.calendar = calendar
	}

	// MARK: - Granting

	/// Builds the record a grant would write, freezing `thresholds` into it.
	///
	/// A failed date computation falls back to the grant day itself, which reads as an
	/// already-expired window. That direction is deliberate: a broken calendar must not hand out
	/// unbounded free access.
	static func record(
		grantedAt: Date,
		thresholds: FreeAccessThresholds,
		calendar: Calendar
	) -> Record {
		let firstDay = calendar.startOfDay(for: grantedAt)
		let expiresAt = calendar.date(byAdding: .day, value: thresholds.grantDays, to: firstDay) ?? firstDay
		let reminderDueAt = calendar.date(byAdding: .day, value: thresholds.reminderOnDay, to: firstDay) ?? firstDay
		return Record(
			grantedAt: grantedAt,
			expiresAt: expiresAt,
			reminderDueAt: reminderDueAt,
			maxObservedDate: grantedAt,
			reminderShown: false
		)
	}

	/// `true` only when both stores have been read and neither held an anchor.
	///
	/// The caller must additionally honour `FeatureFlagKey.isFreeAccessPeriodEnabled`; this
	/// answers the storage half alone. Deliberately *not* expressible as
	/// `phase(at:) == .notGranted`: that is also what ``Anchor/reconciling`` reports.
	var canGrant: Bool { anchor == .absent }

	/// Opens a window at `now`, freezing `thresholds` into it.
	///
	/// Returns the record the caller must persist, or `nil` when ``canGrant`` says no. The caller
	/// is responsible for committing this value only once the durable store has accepted the
	/// record — ``FreeAccessAnchorService/grant(_:)`` does exactly that.
	mutating func grant(at now: Date, thresholds: FreeAccessThresholds) -> Record? {
		guard canGrant else { return nil }
		let record = Self.record(grantedAt: now, thresholds: thresholds, calendar: calendar)
		anchor = .granted(record)
		return record
	}

	// MARK: - Reconciliation

	/// Folds the two stores into the anchor the app must honour.
	///
	/// The **earliest** grant wins, never the newest. The Keychain copy outlives app deletion
	/// precisely so a fresh UserDefaults cannot restart the clock; preferring the newer record
	/// would hand every reinstall a brand-new window, which is the farm the mirror exists to close.
	///
	/// When both stores hold the same grant, the progress fields are merged in the conservative
	/// direction — the higher monotonic floor, and a reminder counted as shown if either store
	/// saw it — so a store disagreement can neither rewind the clamp nor re-nag the user.
	static func reconcile(fast: Record?, durable: Record?) -> Record? {
		guard let fast else { return durable }
		guard let durable else { return fast }
		var winner = fast.grantedAt <= durable.grantedAt ? fast : durable
		winner.maxObservedDate = max(fast.maxObservedDate, durable.maxObservedDate)
		winner.reminderShown = fast.reminderShown || durable.reminderShown
		return winner
	}

	/// Settles the reconciliation gate with the result of reading **both** stores.
	mutating func settle(fast: Record?, durable: Record?) {
		if let record = Self.reconcile(fast: fast, durable: durable) {
			anchor = .granted(record)
		} else {
			anchor = .absent
		}
	}

	// MARK: - Reading

	/// The phase at `now`, with the monotonic clamp applied.
	///
	/// Non-mutating on purpose, so rendering never has a side effect; ``observe(at:)`` is what
	/// advances the clamp floor.
	func phase(at now: Date) -> FreeAccessPhase {
		guard case let .granted(record) = anchor else { return .notGranted }
		// A device clock rolled backwards must not rewind the window, so the floor wins.
		let observedNow = max(now, record.maxObservedDate)
		guard observedNow < record.expiresAt else { return .expired }
		let remaining = remainingDays(from: observedNow, to: record.expiresAt)
		if record.reminderShown == false, observedNow >= record.reminderDueAt {
			return .reminderDue(remaining: remaining)
		}
		return .active(remaining: remaining)
	}

	/// Advances the monotonic floor to `now`.
	///
	/// Returns the updated record when the floor actually moved and therefore needs persisting,
	/// or `nil` when nothing changed.
	mutating func observe(at now: Date) -> Record? {
		guard case .granted(var record) = anchor, now > record.maxObservedDate else { return nil }
		record.maxObservedDate = now
		anchor = .granted(record)
		return record
	}

	/// Records that the reminder has been surfaced, so it is shown once per window.
	///
	/// Returns the updated record to persist, or `nil` when there was nothing to mark.
	mutating func markReminderShown() -> Record? {
		guard case .granted(var record) = anchor, record.reminderShown == false else { return nil }
		record.reminderShown = true
		anchor = .granted(record)
		return record
	}

	/// Whole calendar days between `now`'s day and the frozen expiry.
	///
	/// Floored at 1 because `phase(at:)` only asks before expiry: a device that changed time zone
	/// far enough to push `startOfDay(now)` past `expiresAt` would otherwise report
	/// `.active(remaining: 0)`, which reads as "expired but not expired".
	private func remainingDays(from now: Date, to expiresAt: Date) -> Int {
		let startOfToday = calendar.startOfDay(for: now)
		let days = calendar.dateComponents([.day], from: startOfToday, to: expiresAt).day ?? 1
		return max(days, 1)
	}
}
