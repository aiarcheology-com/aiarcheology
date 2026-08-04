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

	private let service: FreeAccessAnchorService

	/// Captured **once** at construction and deliberately not observed, exactly like
	/// ``SubscriptionState/isPaymentsEnabled`` (AIA-0350): this decides what happens at the app
	/// root, so a mid-session flip would either drop a paywall on a user mid-detection or release a
	/// walled one. A remote change takes effect on the next launch.
	///
	/// It gates **granting only**. A window already open is honoured to its natural expiry even
	/// after the flag reads false: the flag is a tap on the intake, not a revocation of days the
	/// user was already promised.
	private let isFreeAccessPeriodEnabled: Bool

	private let notificationCenter: NotificationCenter
	private var foregroundObservation: AnyCancellable?
	private var expiryTask: Task<Void, Never>?
	private var window = FreeAccessWindow()
	private var hasStarted = false

	init(
		service: FreeAccessAnchorService,
		isFreeAccessPeriodEnabled: Bool,
		notificationCenter: NotificationCenter = .default,
		// Injected (not defaulted to the UIKit constant) so this file needs no UIKit import —
		// `*State` types stay UI-framework-free (ArchitectureTests ratchet, AGENTS §7). The
		// composition root passes `UIApplication.willEnterForegroundNotification`.
		foregroundNotification: Notification.Name
	) {
		self.service = service
		self.isFreeAccessPeriodEnabled = isFreeAccessPeriodEnabled
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
			try? service.grant(&window)
		}

		reevaluate()
	}

	// MARK: - Re-evaluation

	/// Re-reads the clock and republishes. Called by the expiry wake-up and on every foreground.
	///
	/// Safe before ``start(isEntitled:isPaymentsSurfaceEnabled:)`` — availability stays
	/// `.undetermined` rather than collapsing to a guess about a window nobody has read yet.
	func reevaluate() {
		guard hasStarted else { return }
		// Advances the monotonic floor and persists it when it moved, so a device clock wound
		// backwards cannot rewind a window that has already been observed further along.
		service.observe(&window)
		switch service.phase(of: window) {
		case .active, .reminderDue:
			availability = .open
		case .expired, .notGranted:
			availability = .closed
		}
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
