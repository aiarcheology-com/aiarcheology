//
//  FreeAccessWindow.swift
//  AI Archeology
//
//  The app-managed free-access period that precedes the StoreKit paywall (AIA-0556).
//

import Foundation

/// How long a granted window lasts.
///
/// Passed to a grant and frozen into the resulting record — never read again while a window is
/// open. That is the whole point of the type: shortening `grantDays` from 14 to 7 must not wall
/// every mid-window user the moment the new value lands, and lengthening it must not silently
/// hand them days they were never granted. Both are decisions about *new* windows only.
struct FreeAccessThresholds: Equatable, Sendable {
	/// Calendar days of free access, counted from the grant day.
	let grantDays: Int

	/// Normalises on the way in, so a record written from these can never be one the credibility
	/// check will later refuse.
	///
	/// Without this the writer and the reader disagree, and the disagreement runs in the dangerous
	/// direction. An operator lengthening the window past ``FreeAccessWindow/maxCredibleGrantDays``
	/// writes a record the *next* launch finds incredible and rebuilds — into the shipped fourteen
	/// days, since the record's own claim is out of range too. Clamping here means the record that
	/// gets written is always one this app will still recognise as its own.
	init(grantDays: Int) {
		self.grantDays = max(0, min(grantDays, FreeAccessWindow.maxCredibleGrantDays))
	}

	/// The shipped window: 14 days.
	static let standard = FreeAccessThresholds(grantDays: 14)
}

/// What the free-access window is doing at a given instant.
enum FreeAccessPhase: Equatable, Sendable {
	/// No window is open. Also reported while the stores are still being reconciled, which is why
	/// this must never be read as permission to grant — see ``FreeAccessWindow/canGrant``.
	case notGranted

	/// A window is open. `remaining` is whole calendar days left and is always at least 1: the
	/// day it would reach 0 is the day the window is `.expired`.
	case active(remaining: Int)

	/// The window has run out.
	case expired
}

/// A paywall an open window still owes the user (AIA-0556).
///
/// Deliberately not folded into ``FreeAccessPhase``: the phase is what the clock says, this is what
/// has not yet been *said to the user*. The two come apart in both directions — a window can be
/// `.active` and owe nothing, and it can still owe the day-0 explanation days later, because a
/// force-quit before that screen appeared must not swallow it for good.
struct FreeAccessPrompt: Equatable, Sendable {
	/// The window's whole length — "14 days free".
	let days: Int

	/// The instant the window runs out; the date a subscription has to start by.
	let endsOn: Date
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

		/// The latest instant this record has ever been shown — the floor that a device clock
		/// rolled backwards is clamped to.
		var maxObservedDate: Date

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
			maxObservedDate: Date,
			day0Shown: Bool,
			expiryReported: Bool = false
		) {
			self.grantedAt = grantedAt
			self.expiresAt = expiresAt
			self.maxObservedDate = maxObservedDate
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
			maxObservedDate = try container.decode(Date.self, forKey: .maxObservedDate)
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
		return Record(
			grantedAt: grantedAt,
			expiresAt: expiresAt,
			maxObservedDate: grantedAt,
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

	/// The longest window any operator may configure, and therefore the longest a stored record may
	/// claim.
	///
	/// A ceiling on the *thresholds*, not on the raw dates. The shipped window is 14 days and the
	/// values are remote-configurable, so this leaves room to lengthen one deliberately while still
	/// refusing a record that awards itself a year.
	static let maxCredibleGrantDays = 60

	/// The thresholds a stored record implies, or `nil` when they are outside anything an operator
	/// could have configured.
	///
	/// `grantDays == 0` is legitimate and must survive: it is what winding the feature down looks
	/// like, and it describes a window that expired the day it was granted. Treating it as
	/// implausible and rebuilding it into the standard fourteen days would turn switching the
	/// feature off into handing one out.
	static func claimedThresholds(of record: Record, calendar: Calendar) -> FreeAccessThresholds? {
		let firstDay = calendar.startOfDay(for: record.grantedAt)
		guard let grantDays = calendar.dateComponents([.day], from: firstDay, to: record.expiresAt).day,
			  grantDays >= 0, grantDays <= maxCredibleGrantDays
		else { return nil }
		return FreeAccessThresholds(grantDays: grantDays)
	}

	/// Whether this app could actually have written `record`.
	///
	/// The test is a bound, not a reproduction: the grant cannot be in the future, and the window it
	/// claims must be a length an operator could actually have configured. A record outside that is
	/// rebuilt from its own `grantedAt`.
	///
	/// The ceiling is doing all the work here, and it is enough. A forger editing their own storage
	/// can claim at most ``maxCredibleGrantDays``; they could do that before this was relaxed too,
	/// because a record claiming the full ceiling reproduces exactly. What the stricter check added
	/// was that the expiry had to land on local midnight — worth a few hours to an attacker, and
	/// worth real days to an honest user who changed time zone, which is why it is gone.
	///
	/// `now` matters because a grant cannot have happened in the future. That case is repaired
	/// separately by ``reanchoredIfGrantedInTheFuture(_:now:calendar:)``, which re-anchors rather
	/// than rebuilds; this only has to avoid *blessing* it in the meantime.
	static func isCredible(_ record: Record, now: Date, calendar: Calendar) -> Bool {
		guard record.grantedAt <= now.addingTimeInterval(futureGrantTolerance) else { return false }
		// Bounded, not reproduced — deliberately (AIA-0567).
		//
		// This used to rebuild the record from its own `grantedAt` and demand the frozen dates come
		// back identical. That is exact only while the calendar is the one the grant was written
		// under: `claimedThresholds` measures from `startOfDay(grantedAt)`, which moves when the
		// device does, so an honest record stopped reproducing the moment its owner changed time
		// zone and was "repaired" to the new local midnight. It only ever repaired *downward*, and
		// it ratcheted — a Berlin grant loses hours in Los Angeles, then loses more coming back.
		// A fortnight of free access is not something to shave off by flying.
		//
		// Nothing is given up. Reproduction never bounded a forger: a record claiming the full
		// ceiling, aligned to local midnight, reproduces exactly and always did. The bound is
		// ``maxCredibleGrantDays``, which `claimedThresholds` enforces and which is unchanged. All
		// the equality ever caught was an expiry that missed midnight — a few hours to somebody
		// already editing their own storage, against real days taken from an honest traveller.
		return claimedThresholds(of: record, calendar: calendar) != nil
	}

	/// Rebuilds an unreproducible record's durations from its own grant date, leaving a credible one
	/// exactly as it was.
	///
	/// This is the bound that makes earliest-grant-wins safe. Reconciliation prefers the earliest
	/// `grantedAt` and then repairs the losing store from the winner — so a fast record, a plist
	/// editable in an unencrypted backup, needs only an early grant date to win outright and an
	/// inflated `expiresAt` to buy the access, and it would be written into the Keychain as
	/// authoritative on the way past. The tie-break does not reach that; it governs an exact match.
	///
	/// Rebuilding rather than rejecting is deliberate. A rejected record leaves nothing anchored,
	/// and nothing anchored means ``canGrant`` — so refusing a forgery would *reward* it with a
	/// fresh window. Rebuilt, an early grant date yields the window that grant would really have
	/// produced, which has usually long expired: the edit costs its author access instead.
	///
	/// **Honest residual, and it is not closed by this.** A forgery that stays inside
	/// ``maxCredibleGrantDays`` is reproducible and therefore credible, so it keeps what it claims —
	/// bounded at that many days, once, since each later forgery must be earlier still and the
	/// horizon only ratchets down. Device-local storage cannot do better; #557 tracks the durable
	/// answer.
	static func credible(_ record: Record, now: Date, calendar: Calendar) -> Record {
		guard isCredible(record, now: now, calendar: calendar) == false else { return record }
		// Rebuild with the record's *own* thresholds when they are themselves in range, and only
		// fall back to the shipped ones when they are not.
		//
		// This is what keeps an honest traveller whole. `Calendar.current` carries the device's time
		// zone, so flying somewhere else re-aligns midnight and a frozen expiry stops landing exactly
		// on a day boundary — reproduction then fails on equality even though the thresholds it
		// implies are perfectly ordinary. Rebuilding to `.standard` there would silently cut a
		// deliberately-configured 30-day window down to 14 and write that to both stores; rebuilding
		// to what the record actually claims re-aligns it and keeps its length. A forger gains
		// nothing either way, because those thresholds still have to pass the cap.
		let rebuilt = Self.record(
			grantedAt: record.grantedAt,
			thresholds: claimedThresholds(of: record, calendar: calendar) ?? .standard,
			calendar: calendar
		)
		return Record(
			grantedAt: record.grantedAt,
			expiresAt: rebuilt.expiresAt,
			maxObservedDate: record.maxObservedDate,
			day0Shown: record.day0Shown,
			expiryReported: record.expiryReported
		)
	}

	/// Folds the two stores into the anchor the app must honour.
	///
	/// The **earliest** grant wins, never the newest: the Keychain copy outlives app deletion
	/// precisely so a fresh UserDefaults cannot restart the clock, and preferring the newer record
	/// would hand every reinstall a brand-new window.
	///
	/// Both records must already have passed ``credible(_:now:calendar:)`` — earliest-wins is only
	/// safe on records this app could have written, since otherwise an edited one needs nothing but
	/// an early date to win.
	/// Folds the two stores into the anchor the app must honour.
	///
	/// The **earliest** grant wins, never the newest. The Keychain copy outlives app deletion
	/// precisely so a fresh UserDefaults cannot restart the clock; preferring the newer record
	/// would hand every reinstall a brand-new window, which is the farm the mirror exists to close.
	///
	/// When both stores hold the same grant, the progress fields are merged in the conservative
	/// direction — the higher monotonic floor, and a screen counted as shown if either store saw
	/// it — so a store disagreement can neither rewind the clamp nor re-nag the user.
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
		// `day0Shown` merges as "shown if either store saw it": it is the whole of `duePrompt(at:)`,
		// so a marker lost because the *other* store happened to win the tie re-offers "14 days free"
		// to someone already a week into their window.
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
		let rebuilt = Self.record(
			grantedAt: now,
			thresholds: FreeAccessThresholds(grantDays: grantDays),
			calendar: calendar
		)

		return Record(
			grantedAt: rebuilt.grantedAt,
			expiresAt: rebuilt.expiresAt,
			// Reset with the anchor. Leaving the forged floor in place would re-create the same
			// unbounded window the repair exists to end.
			maxObservedDate: now,
			// Progress is kept: whatever the clock said, the user did see that screen.
			day0Shown: record.day0Shown
			// `expiryReported` deliberately resets to its default. This is a new window with a new
			// expiry ahead of it, and the stage it will eventually reach is one nobody has reported.
		)
	}

	/// Settles the reconciliation gate with the result of reading **both** stores.
	///
	/// Records must already have passed ``credible(_:now:calendar:)`` — `FreeAccessAnchorService`
	/// applies it as each store is read, which is the only place storage is ever loaded.
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
		return .active(remaining: remainingDays(from: observedNow, to: record.expiresAt))
	}

	/// The day-0 paywall this window still owes the user at `now`, or `nil` when it owes none.
	///
	/// An expired window owes nothing. A user away from day 5 to day 16 meets the wall, and being
	/// offered "14 days free" on the way to it would be a lie — the window it describes is already
	/// spent.
	func duePrompt(at now: Date) -> FreeAccessPrompt? {
		guard case let .granted(record) = anchor else { return nil }
		switch phase(at: now) {
		case .notGranted, .expired:
			return nil
		case let .active(remaining):
			guard record.day0Shown == false else { return nil }
			// What is *left*, not what was granted. These are the same number on day 0, which is the
			// only day this normally appears — but `day0Shown` is written at presentation, so a user
			// who force-quits before the screen renders is owed it again later, and telling someone
			// on day 5 that they have "14 days free" overstates the offer by the days they spent.
			//
			// Taken from the phase rather than recomputed, so the screen and the gate can never
			// disagree. `phase(at:)` counts from `max(now, maxObservedDate)` — the monotonic floor
			// that stops a rolled-back clock rewinding the window — and an independent count from
			// the raw `now` would let the Welcome screen advertise days the gate does not believe in.
			return FreeAccessPrompt(days: remaining, endsOn: record.expiresAt)
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
