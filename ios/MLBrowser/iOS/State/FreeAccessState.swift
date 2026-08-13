//
//  FreeAccessState.swift
//  AI Archeology
//
//  Observable owner of the app-managed free-access window (AIA-0556).
//

import Combine
import Foundation

/// What the app root should do about free access, as one answer rather than two booleans.
///
/// The third case is the whole reason this type exists. ``FreeAccessWindow/phase(at:)`` reports
/// `.notGranted` while the two anchor stores are still being read, and its own documentation warns
/// that this must never be read as permission to grant. The mirror-image mistake is just as
/// expensive: a gate that reads "not granted" as "wall this user" flashes the paywall in front of
/// someone whose window is perfectly valid, on every single launch, for as long as the Keychain
/// takes to answer. So the gate is told "not yet" and renders neither side until an answer exists.
enum FreeAccessAvailability: Equatable, Sendable {
	/// The anchor has not been reconciled yet. Neither the app nor the wall may be shown.
	case undetermined

	/// A window is open.
	case open

	/// Reconciliation finished and no window is open — never granted, or expired.
	case closed
}

/// Owns the app-managed free-access window for the UI (AIA-0556): reconciliation on startup, the
/// grant decision, the published availability, and the wake-up that ends the window on time.
///
/// A thin wrapper by design — every transition lives in the pure ``FreeAccessWindow`` value and
/// every store access in ``FreeAccessAnchorService``, mirroring the ``FeatureFlagSnapshot`` /
/// ``FeatureFlagsState`` split. What is *not* delegated is the ordering, which is the part that can
/// silently break: reconcile, then decide whether to grant, then publish.
@MainActor
final class FreeAccessState: ObservableObject {

	/// The single answer the root gate consults. Starts ``FreeAccessAvailability/undetermined`` and
	/// leaves it for good the first time ``start(isEntitled:isPaymentsSurfaceEnabled:)`` runs.
	@Published private(set) var availability: FreeAccessAvailability = .undetermined

	/// When the pending expiry wake-up is set for, or `nil` when none is armed.
	///
	/// Exposed rather than kept private because the wake-up is the difference between "walled on day
	/// 14" and "never walled for as long as the app stays open" — see ``scheduleExpiry()``.
	/// Something has to be able to assert it is actually armed.
	private(set) var scheduledExpiry: Date?

	/// Whether a window granted on *this* launch is still waiting for the paywall that explains it.
	///
	/// It exists so the analytics consent question cannot jump the queue. `AnalyticsChoiceGate` is
	/// nested inside the root gate and replaces its content full-screen while consent is `.ask`, so
	/// the moment a granted window opens that gate the first thing a brand-new user would meet is
	/// "Enable analytics?" — with `ContentView`, and therefore the onboarding tour, not yet mounted.
	/// The intended first run is Welcome → tour → consent (AIA-0447, reordered by AIA-0567); this
	/// holds the ask back until the free window has been introduced, and `TourState` holds it back
	/// for the tour that follows.
	///
	/// **In memory only, deliberately.** A force-quit before the Welcome screen appears lets the next
	/// launch ask normally, so the question is only ever *deferred* — no persisted marker can leave
	/// a user who is never asked again. It is also false for everyone who was not granted a window
	/// on this launch, which is every returning user.
	@Published private(set) var isDay0AcknowledgementPending = false

	/// The day-0 paywall the open window still owes the user, or `nil` when it owes none.
	///
	/// Recomputed on every ``reevaluate()``, so a window whose explanation never made it on screen —
	/// a force-quit before it appeared — is owed it again on the next foreground rather than losing
	/// it for good. It answers only *what* is owed — **when** it may go on screen is the root gate's
	/// call. That used to mean waiting for the onboarding tour; since AIA-0567 it is the other way
	/// round, and the tour waits for this.
	@Published private(set) var duePrompt: FreeAccessPrompt?

	/// The windows that currently have a Welcome screen on screen, one token each (AIA-0567).
	///
	/// Shared rather than scene-local, and that is the point. `SubscriptionGateView` holds its own
	/// `presentedPrompt` in `@State`, which is per-window, while this object and `TourState` are
	/// owned by `AppState` and shared across the whole `WindowGroup` — and the app ships with
	/// `UIApplicationSupportsMultipleScenes`, so two iPad windows are a real configuration.
	///
	/// Without it, two windows defeat the ordering this ticket imposes: window A raises the Welcome
	/// screen and in doing so clears the shared `duePrompt`; window B then sees nothing owed,
	/// concludes the screen is free, and starts the shared tour — which runs visibly in B and
	/// *underneath* the Welcome screen in A.
	///
	/// **Tokens, claimed synchronously, and both halves of that matter.**
	///
	/// *Synchronously*, because the claim has to be in place before the publish that starts the
	/// race. `markPromptShown()` clears `duePrompt` on the same turn the screen is raised, and that
	/// publish is what wakes the other window; a claim taken later — when the overlay appears, a
	/// render commit afterwards — leaves a gap in which B sees nothing owed and nothing presented,
	/// and starts the tour anyway. Cross-scene commit order is not specified, so that gap is a race
	/// on exactly the event the guard exists for.
	///
	/// *Tokens* rather than a count, because release must be idempotent and attributable. A window
	/// releases the claim it took, so a duplicated `onDisappear` cannot decrement twice and a
	/// spurious one belonging to a torn-down scene cannot release a live sibling's screen. A bare
	/// count made both of those silent, and a `Bool` before it leaked permanently.
	@Published private(set) var welcomeClaims: Set<UUID> = []

	/// Whether a Welcome screen is on screen in **any** window.
	var isWelcomePresented: Bool { welcomeClaims.isEmpty == false }

	/// Claims the Welcome screen for the calling window. Call this *before* anything that publishes.
	func claimWelcomePresentation() -> UUID {
		let token = UUID()
		welcomeClaims.insert(token)
		return token
	}

	/// Releases one window's claim. Safe to call more than once with the same token, and safe to
	/// call for a window whose claim was already released — both are no-ops.
	func releaseWelcomePresentation(_ token: UUID) {
		welcomeClaims.remove(token)
	}

	private let service: FreeAccessAnchorService

	/// The funnel this window feeds (AIA-0556). Optional and defaulted for the same reason
	/// ``DetectionSessionState`` and ``AppChromeState`` take it that way: analytics is a bolt-on the
	/// feature must work without, and every test that is not about reporting can leave it out.
	///
	/// Two of the three free-access stages are emitted from here rather than from the gate, because
	/// this is where they *happen*: a grant and an expiry have no screen at all. Events raised before
	/// the consent question is answered are buffered by ``AnalyticsState`` and delivered only if the
	/// user later enables analytics — which is most of them now that the ask is deferred past the
	/// day-0 paywall.
	private let analytics: AnalyticsState?

	/// Captured **once** at construction and deliberately not observed, exactly like
	/// ``SubscriptionState/isPaymentsEnabled`` (AIA-0350): this decides what happens at the app
	/// root, so a mid-session flip would either drop a paywall on a user mid-detection or release a
	/// walled one. A remote change takes effect on the next launch.
	///
	/// It gates **granting only**. A window already open is honoured to its natural expiry even
	/// after the flag reads false: the flag is a tap on the intake, not a revocation of days the
	/// user was already promised.
	private let isFreeAccessPeriodEnabled: Bool

	/// Whether access is closed because a window ran out, as opposed to one never having been granted
	/// (AIA-0567).
	///
	/// ``availability`` deliberately collapses both into ``FreeAccessAvailability/closed`` — for
	/// deciding whether to wall someone they are the same answer. They are not the same *sentence*:
	/// the paywall may only say "your free access has ended" to a user who actually had some, and
	/// telling a user who never had a window that theirs ran out is a plain untruth.
	///
	/// Computed rather than a stored latch. `availability` already has two writers, and a second
	/// published flag set only in the `.expired` branch is one refactor away from disagreeing with
	/// it. Nothing observes this on its own: it is read during `body` next to `availability`, which
	/// does publish, so the re-render that can change the answer is the one that already happens.
	var hasSpentWindow: Bool {
		guard hasStarted else { return false }
		return service.phase(of: window) == .expired
	}

	/// Whole calendar days left in the open window, or `nil` when none is open (AIA-0623).
	///
	/// For the one surface that has to *say* the number rather than compare against it: the
	/// confirmation shown before a purchase forfeits the rest of the window.
	///
	/// **Taken from the phase, never recomputed from ``windowEndsOn``.** That is not a style
	/// preference — `phase(of:)` counts from `max(now, maxObservedDate)`, the monotonic floor that
	/// stops a device clock wound backwards from rewinding a window, so an independent count from
	/// the raw clock would offer a user days the gate does not believe in. It is the same rule
	/// ``FreeAccessWindow/duePrompt(at:)`` states for the Welcome screen, for the same reason.
	///
	/// Computed rather than `@Published`, exactly like ``hasSpentWindow``: the answer only changes
	/// when the clock does, and it is read during `body` next to ``availability``, which does
	/// publish — so the re-render that can change the answer is the one that already happens.
	var windowDaysRemaining: Int? {
		guard hasStarted, case let .active(remaining) = service.phase(of: window) else { return nil }
		return remaining
	}

	private let notificationCenter: NotificationCenter
	private var foregroundObservation: AnyCancellable?
	private var expiryTask: Task<Void, Never>?
	private var window = FreeAccessWindow()
	private var hasStarted = false

	init(
		service: FreeAccessAnchorService,
		isFreeAccessPeriodEnabled: Bool,
		analytics: AnalyticsState? = nil,
		notificationCenter: NotificationCenter = .default,
		// Injected (not defaulted to the UIKit constant) so this file needs no UIKit import —
		// `*State` types stay UI-framework-free (ArchitectureTests ratchet, AGENTS §7). The
		// composition root passes `UIApplication.willEnterForegroundNotification`.
		foregroundNotification: Notification.Name
	) {
		self.service = service
		self.isFreeAccessPeriodEnabled = isFreeAccessPeriodEnabled
		self.analytics = analytics
		self.notificationCenter = notificationCenter

		// Half of the expiry story. A backgrounded app has no running wake-up to fire, so a window
		// that ran out overnight is only noticed here; `scheduleExpiry()` covers the other half, a
		// session left open across the last midnight.
		foregroundObservation = notificationCenter
			.publisher(for: foregroundNotification)
			.sink { [weak self] _ in
				// UIKit posts this on the main thread, so the sink is already main-actor isolated —
				// assume it rather than schedule an extra hop (AGENTS §4), as `MessageCenterState` does.
				MainActor.assumeIsolated {
					self?.reevaluate()
				}
			}
	}

	deinit {
		// `Task` is `Sendable`, so it is the only thing a nonisolated deinit may touch; the
		// `AnyCancellable` cancels itself as this object is torn down (see `MessageCenterState`).
		expiryTask?.cancel()
	}

	// MARK: - Startup

	/// Reconciles the two anchor stores, opens a window when nothing forbids it, and publishes the
	/// first real answer. Idempotent; later calls do nothing.
	///
	/// `isEntitled` is the caller's live StoreKit entitlement, and it is a **refusal to grant**, not
	/// a gate on honouring: a user who already pays — or who is inside Apple's trial — has no use
	/// for a 14-day app window, and one granted silently in the background would only expire under
	/// them later for no cause they could see. Their free period is Apple's, and StoreKit owns it.
	/// A window granted *before* they subscribed is untouched, and keeps running underneath.
	///
	/// `isPaymentsSurfaceEnabled` is a refusal to grant for a different reason: with payments off
	/// there is no gate to be let through, so a window would be a clock running down behind a door
	/// that is already open. Ship the feature dark for two months and every install would burn its
	/// 14 days unseen, then meet the wall the instant payments were switched on — with no free
	/// period at all, which is the exact opposite of the point. A window is therefore measured from
	/// the first launch on which payments are live, not from install.
	///
	/// Local reads only: nothing here waits on the network, and the two store reads are the entire
	/// cost of the call.
	func start(isEntitled: Bool, isPaymentsSurfaceEnabled: Bool) {
		guard hasStarted == false else { return }
		hasStarted = true

		window = service.reconciledWindow()

		// `canGrant` is `false` while the stores are unreconciled, which is what stops a failed
		// Keychain read from writing a fresh anchor over a mirror nobody could look at. The grant
		// itself fails closed: a durable write failure leaves `window` untouched, so this session
		// has no window rather than a farmable one.
		if isFreeAccessPeriodEnabled, isPaymentsSurfaceEnabled, isEntitled == false, window.canGrant {
			// Only a grant that actually landed owes the user an explanation. A durable-write failure
			// leaves them with no window at all, and deferring the consent question on the strength
			// of a window that does not exist would silence it for a launch for no reason.
			isDay0AcknowledgementPending = (try? service.grant(&window)) == true
			// Reported off the same value, so the funnel counts windows that actually opened. A
			// grant that failed its durable write left the user with nothing, and a stage reported
			// for it would make every later stage look like drop-off.
			if isDay0AcknowledgementPending { analytics?.track(.freeAccessWindowGranted) }
		}

		reevaluate()
	}

	/// Records that the paywall introducing the free window has had its turn, releasing the consent
	/// question that was waiting behind it.
	///
	/// Called by whatever presents that paywall, on any exit from it — continue or subscribe. It is
	/// the only thing that ends the deferral within a session; a launch that never presents it simply
	/// asks on the next one.
	func acknowledgeDay0Presentation() {
		isDay0AcknowledgementPending = false
	}

	/// Records that `prompt` has been put on screen, so it is shown once per window and never again.
	///
	/// Called at **presentation**, not at dismissal, and that ordering is the whole contract: a
	/// force-quit while the paywall is up must not make it fire again on every later launch, and one
	/// that happens before it was ever raised must not lose it. Persisting immediately also means the
	/// caller cannot keep reading ``duePrompt`` as "what is on screen" — it stops being due the
	/// instant it is shown, which is why the presenter holds its own copy.
	func markPromptShown() {
		let didMark = service.markDay0Shown(&window)
		// Reported here rather than from the presenter because *this* is the call that writes the
		// once-per-window marker: the screen can only reach this line while it is still due, so the
		// event cannot outnumber the screen (the guarantee the retired reminder event had).
		//
		// Day 0 used to need no counterpart, on the grounds that `paywall.shown` already covered the
		// screen and `window_granted` covered the window it explains. AIA-0567 ended that: the
		// day-0 screen is now ``WelcomeView``, which is deliberately not a purchase screen and
		// deliberately does not emit `paywall.shown`. Without this the funnel loses the stage
		// outright — and `window_granted` cannot stand in for it, because the two come apart exactly
		// where it matters: a force-quit between the grant and the presentation.
		if didMark { analytics?.track(.welcomeShown) }
		duePrompt = service.duePrompt(for: window)
	}

	// MARK: - Re-evaluation

	/// Re-reads the clock and republishes. Called by the expiry wake-up and on every foreground.
	///
	/// Safe before ``start(isEntitled:isPaymentsSurfaceEnabled:)`` — availability stays
	/// `.undetermined` rather than collapsing to a guess about a window nobody has read yet.
	/// When the open window runs out, for anything that needs to *say* so — `nil` when none is open.
	///
	/// Separate from ``scheduledExpiry``, which is a timer's business and is cleared once the window
	/// has closed. This is the date the user is told, and Settings shows it so the free period is
	/// not something they have to infer from a paywall they may not have seen for a week.
	@Published private(set) var windowEndsOn: Date?

	func reevaluate() {
		guard hasStarted else { return }
		// Advances the monotonic floor and persists it when it moved, so a device clock wound
		// backwards cannot rewind a window that has already been observed further along.
		service.observe(&window)
		switch service.phase(of: window) {
		case .active:
			availability = .open
		case .expired:
			availability = .closed
			// Split from `.notGranted` purely so this can fire: both close access, but only one of
			// them is a window that ran out. Reporting the other would count every user who never
			// had a window — the whole population with the flag off — as a lapsed free trial.
			// Two guards, because this line runs on every launch and every foreground for the rest
			// of the install's life. The claim below is the durable one: it rides the anchor, so a
			// reinstall cannot make one window report its own expiry twice — the window outlives the
			// install by design, and an install-scoped marker alone would not. `AnalyticsState`
			// keeps its own guard for the consent-buffering case it already handles.
			if service.markExpiryReported(&window) {
				analytics?.reportFreeAccessWindowExpiredIfNeeded()
			}
		case .notGranted:
			availability = .closed
		}
		duePrompt = service.duePrompt(for: window)
		windowEndsOn = availability == .open ? window.expiresAt : nil
		scheduleExpiry()
	}

	/// Arms a one-shot wake-up at the exact expiry instant.
	///
	/// Without it a `Date`-derived phase never recomputes itself: a user who leaves the app
	/// foregrounded across their last midnight is never walled, because nothing re-reads the clock.
	///
	/// The delay is measured against the real clock rather than the service's injected one, because
	/// a sleep duration is a wall-clock quantity — and because a test clock parked in the past would
	/// otherwise arm a wake-up that fires instantly, re-publishes `.open`, and re-arms forever.
	private func scheduleExpiry() {
		expiryTask?.cancel()
		expiryTask = nil
		scheduledExpiry = nil

		guard availability == .open, case let .granted(record) = window.anchor else { return }
		let delay = record.expiresAt.timeIntervalSinceNow
		guard delay > 0 else { return }

		scheduledExpiry = record.expiresAt
		expiryTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			guard Task.isCancelled == false else { return }
			self?.reevaluate()
		}
	}
}
