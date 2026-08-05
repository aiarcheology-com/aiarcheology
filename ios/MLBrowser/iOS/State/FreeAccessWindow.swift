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

/// A paywall an open window still owes the user (AIA-0556).
///
/// Deliberately not folded into ``FreeAccessPhase``: the phase is what the clock says, this is what
/// has not yet been *said to the user*. The two come apart in both directions — a window can be
/// `.active` and owe nothing, and it can still owe the day-0 explanation days later, because a
/// force-quit before that screen appeared must not swallow it for good.
enum FreeAccessPrompt: Equatable, Sendable {
	/// The window has never been explained. `days` is its whole length — "14 days free".
	case day0(days: Int, endsOn: Date)

	/// The reminder day has arrived and the reminder has not been shown. `days` is what is left.
	case reminder(days: Int, endsOn: Date)
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

		/// Whether the day-0 paywall that explains this window has already been surfaced.
		///
		/// Written when that screen is *shown*, never when it is dismissed: a force-quit while it is
		/// up must not make it reappear on every later launch, and one that happens before it was
		/// ever raised must not lose it. Durable like the rest of the record, so a reinstall does not
		/// re-offer "14 days free" to someone with three days left.
		var day0Shown: Bool

		/// Whether `free_access.window_expired` has already been reported for *this* window.
		///
		/// It lives here rather than in `Settings` because the window outlives the install: the
		/// Keychain mirror is what makes delete-and-reinstall resume rather than restart, so an
		/// install-scoped marker would let one window report its own expiry twice — once before the
		/// reinstall and once after. A funnel stage that can fire twice for one window is a launch
		/// counter wearing a stage's name.
		var expiryReported: Bool

		init(
			grantedAt: Date,
			expiresAt: Date,
			reminderDueAt: Date,
			maxObservedDate: Date,
			reminderShown: Bool,
			day0Shown: Bool,
			expiryReported: Bool = false
		) {
			self.grantedAt = grantedAt
			self.expiresAt = expiresAt
			self.reminderDueAt = reminderDueAt
			self.maxObservedDate = maxObservedDate
			self.reminderShown = reminderShown
			self.day0Shown = day0Shown
			self.expiryReported = expiryReported
		}

		/// Tolerates a stored record written before ``day0Shown`` existed instead of rejecting it.
		///
		/// The Keychain mirror deliberately outlives app deletion — and `simctl erase` — so a record
		/// in the older shape is not hypothetical on any device this feature has ever run on. An
		/// absent marker reads as "not shown yet"; the synthesized decoder would instead throw, and a
		/// throw here discards the whole anchor, which is precisely the resume-don't-restart
		/// guarantee the mirror exists to provide.
		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			grantedAt = try container.decode(Date.self, forKey: .grantedAt)
			expiresAt = try container.decode(Date.self, forKey: .expiresAt)
			reminderDueAt = try container.decode(Date.self, forKey: .reminderDueAt)
			maxObservedDate = try container.decode(Date.self, forKey: .maxObservedDate)
			reminderShown = try container.decode(Bool.self, forKey: .reminderShown)
			day0Shown = try container.decodeIfPresent(Bool.self, forKey: .day0Shown) ?? false
			expiryReported = try container.decodeIfPresent(Bool.self, forKey: .expiryReported) ?? false
		}
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
			reminderShown: false,
			day0Shown: false
		)
	}

	/// When the anchored window runs out, or `nil` while there is no anchor to ask.
	///
	/// For surfaces that need to *state* the date rather than compare against it. Callers must still
	/// consult the phase for whether the window is open — a record exists for an expired one too.
	var expiresAt: Date? {
		guard case let .granted(record) = anchor else { return nil }
		return record.expiresAt
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
		// The durable copy wins an exact tie. Both stores hold the same record after a legitimate
		// grant, so the direction is invisible in normal use — it matters when they differ. The fast
		// copy is a plain UserDefaults plist, editable in an unencrypted local backup; the Keychain
		// copy is not. Preferring `fast` here would let an inflated `expiresAt` win the tie *and*
		// then be written back over the durable record by `reconciledWindow`'s repair, laundering
		// the edit into the store that is supposed to be authoritative.
		var winner = fast.grantedAt < durable.grantedAt ? fast : durable

		// Progress belongs to a *window*, not to a device, so it is only merged between two records
		// describing the same one. Folding a discarded anchor's progress into the survivor is not
		// conservative, it is wrong in both directions: the loser's monotonic floor can sit past the
		// winner's expiry and wall a user before their window has actually run out, and its
		// shown-markers would suppress screens the surviving window has never presented.
		guard fast.grantedAt == durable.grantedAt else { return winner }

		winner.maxObservedDate = max(fast.maxObservedDate, durable.maxObservedDate)
		winner.reminderShown = fast.reminderShown || durable.reminderShown
		// `day0Shown` merges the same way, and for a sharper reason than the reminder: it outranks
		// everything in `duePrompt(at:)`, so a marker lost because the *other* store happened to win
		// the tie re-offers "14 days free" to someone already a week into their window.
		winner.day0Shown = fast.day0Shown || durable.day0Shown
		// Same direction, so one window cannot report its expiry twice because the stores disagreed
		// about whether it already had.
		winner.expiryReported = fast.expiryReported || durable.expiryReported
		return winner
	}

	/// How far ahead of the clock a grant may legitimately sit before it is treated as forged.
	///
	/// A grant is stamped with the device's own clock, so `grantedAt` should never be in the future.
	/// The tolerance absorbs the ordinary reasons it might be by a hair — a clock corrected by NTP
	/// moments after the grant, or a record written either side of a leap second — without leaving
	/// room for the attack below.
	static let futureGrantTolerance: TimeInterval = 60 * 60 * 24

	/// Re-anchors a window that was granted under a **forward-dated** device clock, or `nil` when
	/// the record is ordinary and needs no repair.
	///
	/// The attack this closes is cheap and permanent, and the monotonic floor is what made it stick.
	/// Set the device date to 2030 before the first launch, take the grant, then put the clock back.
	/// `grantedAt` and `maxObservedDate` are both stamped 2030, and `phase(at:)` clamps
	/// `observedNow` to that floor precisely so a *rollback* cannot rewind a window — so the window
	/// reports itself perpetually fresh until real wall-time reaches 2030. Nothing ends it: the
	/// floor only moves forward, and the expiry wake-up is scheduled years out.
	///
	/// Re-anchoring to `now` rather than expiring the window is deliberate. A clock far ahead is
	/// usually a tester or someone who mis-set the date, not an attacker, and the honest response to
	/// "this anchor cannot be true" is to start the window from the first moment we can trust rather
	/// than to punish. An attacker gains nothing either way: they end up with the same fourteen days
	/// they would have had by not touching the clock at all.
	///
	/// The frozen durations are carried across rather than re-read from current thresholds, so the
	/// repair cannot quietly re-length or shorten a window either (see ``FreeAccessThresholds``).
	static func reanchoredIfGrantedInTheFuture(
		_ record: Record,
		now: Date,
		calendar: Calendar
	) -> Record? {
		guard record.grantedAt > now.addingTimeInterval(futureGrantTolerance) else { return nil }

		let originalStart = calendar.startOfDay(for: record.grantedAt)
		let grantDays = calendar.dateComponents([.day], from: originalStart, to: record.expiresAt).day ?? 0
		let reminderDay = calendar.dateComponents([.day], from: originalStart, to: record.reminderDueAt).day ?? 0
		let rebuilt = Self.record(
			grantedAt: now,
			thresholds: FreeAccessThresholds(grantDays: grantDays, reminderOnDay: reminderDay),
			calendar: calendar
		)

		return Record(
			grantedAt: rebuilt.grantedAt,
			expiresAt: rebuilt.expiresAt,
			reminderDueAt: rebuilt.reminderDueAt,
			// Reset with the anchor. Leaving the forged floor in place would re-create the same
			// unbounded window the repair exists to end.
			maxObservedDate: now,
			// Progress is kept: whatever the clock said, the user did see those screens.
			reminderShown: record.reminderShown,
			day0Shown: record.day0Shown
			// `expiryReported` deliberately resets to its default. This is a new window with a new
			// expiry ahead of it, and the stage it will eventually reach is one nobody has reported.
		)
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

	/// Which paywall this window still owes the user at `now`, or `nil` when it owes none.
	///
	/// Day 0 outranks the reminder: a window that has never been explained has to be explained
	/// before it is counted down, and the two only coincide for someone who did not open the app
	/// between the grant and the reminder day.
	///
	/// An expired window owes neither. That is the rule that keeps the reminder from firing late —
	/// a user who is away from day 5 to day 16 meets the wall, and being told "7 days left" on the
	/// way to it would be a lie.
	func duePrompt(at now: Date) -> FreeAccessPrompt? {
		guard case let .granted(record) = anchor else { return nil }
		let day0 = FreeAccessPrompt.day0(days: grantedDays(of: record), endsOn: record.expiresAt)
		switch phase(at: now) {
		case .notGranted, .expired:
			return nil
		case .active:
			return record.day0Shown ? nil : day0
		case let .reminderDue(remaining):
			guard record.day0Shown else { return day0 }
			return .reminder(days: remaining, endsOn: record.expiresAt)
		}
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

	/// Claims the right to report this window's expiry, once.
	///
	/// Returns the record to persist the first time it is called for a given window, and `nil`
	/// every time after — including after a reinstall, because the marker rides the durable anchor
	/// rather than the install. The expiry phase is re-observed on every launch and every foreground
	/// for the rest of the install's life, so without a durable claim the funnel counts launches
	/// instead of windows.
	mutating func markExpiryReported() -> Record? {
		guard case .granted(var record) = anchor, record.expiryReported == false else { return nil }
		record.expiryReported = true
		anchor = .granted(record)
		return record
	}

	/// Records that the day-0 paywall has been surfaced, so it is shown once per window.
	///
	/// Returns the updated record to persist, or `nil` when there was nothing to mark.
	mutating func markDay0Shown() -> Record? {
		guard case .granted(var record) = anchor, record.day0Shown == false else { return nil }
		record.day0Shown = true
		anchor = .granted(record)
		return record
	}

	/// The window's whole length in calendar days — the "14 days free" day 0 offers.
	///
	/// Recomputed from the record rather than read off ``FreeAccessThresholds``, for the same reason
	/// the thresholds are frozen at grant: the values in force today are not necessarily the ones
	/// this window was opened with, and the offer must state the window the user actually has.
	private func grantedDays(of record: Record) -> Int {
		let firstDay = calendar.startOfDay(for: record.grantedAt)
		return max(calendar.dateComponents([.day], from: firstDay, to: record.expiresAt).day ?? 1, 1)
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
