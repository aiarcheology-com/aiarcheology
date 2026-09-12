//
//  DetectionSessionState.swift
//  AI Archeology
//
//  AIA-0391: the detection-session controller split out of the former `Guide` god-object.
//  Owns the on-the-fly detection lifecycle and is the SINGLE commander of the snapshot timer
//  (`snap.startTimer()/stopTimer()`) — the timer object itself is owned by `SnapState`; this type
//  is the only place that starts/stops it, making timer ownership unambiguous. App-chrome and
//  navigation state live in the sibling `AppChromeState`.
//

import Foundation

@MainActor
final class DetectionSessionState: ObservableObject {
	let snap: SnapState
	let settings: Settings
	unowned let snapAdjustment: SnapAdjustment
	private let analytics: AnalyticsState?

	@Published var ontheflyDetectionEnabled: Bool = false
	/// Monotonically changes at each public detection lifecycle boundary. Snapshot consumers use it
	/// to reject a result that began in an earlier run but completed after pause/restart/reset.
	@Published private(set) var detectionRunID: UInt64 = 0
	@Published var showSnapAdjustment: Bool = false
	/// Whether the browser chrome (navigation bar with address field and buttons) is visible.
	/// Only meaningful while `ontheflyDetectionEnabled` is true; always reset to `true`
	/// when detection stops. Uniform rule: every detection start hides chrome (provided
	/// `settings.fullscreenDetection` is enabled), every stop shows it — regardless of
	/// initiator (user tap, auto-start, background/foreground cycle, application reset).
	/// Views mutate it via `chromeToggleTapped()`.
	@Published private(set) var chromeVisible: Bool = true
	/// Detection is enabled but nothing may be captured: the web content process died and the
	/// document replacing it has not finished loading (AIA-0879).
	///
	/// Distinct from both other ways detection can be idle. The finding-capture freeze is brief and
	/// user-driven; the background pause turns detection off outright and resumes it on return. This
	/// one keeps the run alive across a recovery the user did not ask for and must not resume early:
	/// detection used to restart 0.2s after the reload was issued, on a page that had not committed,
	/// which is what fed the loop.
	private(set) var isInterruptedByContentLoss = false
	/// Escalates a site that kills its renderer twice from an interruption to a full stop.
	private var terminationPolicy = WebContentTerminationPolicy()
	/// The highest web-content event sequence already answered.
	///
	/// One counter for every kind of event, because they arrive on one publisher. The signal comes
	/// through a `@Published` value that SwiftUI redelivers: it replays to every new subscriber, and
	/// during a view transition the outgoing and incoming subscriptions can both receive the same
	/// live change. Answering one physical termination twice would spend the site's strike and end
	/// the run on a single death, so the sequence is consumed HERE — in the app-scoped controller
	/// that outlives the view — rather than by dropping deliveries at the view, which cannot tell a
	/// replay from a repeat (raised in review).
	private var lastAnsweredWebContentEvent: UInt64 = 0

	init(
		snap: SnapState,
		settings: Settings,
		snapAdjustment: SnapAdjustment,
		analytics: AnalyticsState? = nil
	) {
		self.snap = snap
		self.settings = settings
		self.snapAdjustment = snapAdjustment
		self.analytics = analytics
	}

	/// Fullscreen = detection running and chrome hidden (the default while detecting).
	var isFullscreen: Bool { ontheflyDetectionEnabled && chromeVisible.not }

	/// The floating chrome-toggle button accompanies detection for its whole duration,
	/// regardless of whether the chrome is currently revealed — but only when the
	/// fullscreen feature is enabled in Settings.
	var showsFloatingChromeButton: Bool { ontheflyDetectionEnabled && settings.fullscreenDetection }

	func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			detectionRunID &+= 1
			snap.stopTimer()
			// Deliberately does NOT clear an outstanding interruption. This is not a "capture now"
			// gesture — Settings calls it whenever the snapshot frequency changes — so treating it as
			// proof that the web content is ready would admit snapshots into a document that is still
			// replacing a dead renderer (raised in review). `webContentDidLoad()` owns that decision.
			if mayCapture {
				snap.startTimer(for: detectionRunID)
			}
		}
	}

	/// - Parameter isUserInitiated: `false` for the automatic background pause and the foreground
	///   resume, which are one detection session either side of a suspend rather than two. They must
	///   not clear an outstanding interruption or refill the escalation budget: a termination, a
	///   background, and a return would otherwise resume capture into the still-recovering page AND
	///   forget the site's strike, so the very loop this exists to break would survive a trip to the
	///   home screen (raised in review).
	func ontheflyDetectionTapped(recordAnalytics: Bool = true, isUserInitiated: Bool = true) {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			detectionRunID &+= 1
			chromeVisible = settings.fullscreenDetection.not
			// A run the user starts begins with a clean slate: no outstanding interruption, and a
			// fresh strike for every site. Their intent replenishes the budget, the same rule
			// `WebContentRecoveryPolicy.userDidNavigate()` applies to the recovery ladder.
			if isUserInitiated {
				isInterruptedByContentLoss = false
				terminationPolicy = WebContentTerminationPolicy()
			}
			// Still interrupted means the page that killed the renderer has not come back yet, so the
			// run resumes without capture and `webContentDidLoad()` starts the timer.
			if mayCapture {
				snap.startTimer(for: detectionRunID)
			}
			if recordAnalytics {
				analytics?.recordDetectionRun()
			}
		} else {
			detectionRunID &+= 1
			chromeVisible = true
			// An open adjustment overlay would be orphaned once its toolbar
			// button disappears with detection mode.
			showSnapAdjustment = false
			if isUserInitiated {
				isInterruptedByContentLoss = false
			}
			snap.stopTimer()
		}
	}

	func chromeToggleTapped() {
		chromeVisible.toggle()
	}

	/// Detection was running when the finding-save dialog opened; only then does
	/// ending the capture resume the timer.
	private var detectionWasRunningBeforeCapture = false

	/// A finding-save dialog opened: stop the snapshot timer so no new passes start.
	/// Only the timer is owned here — the displayed-frame freeze (generation bump,
	/// queue cancellation, apply gating) lives in DetectableView, which owns that state.
	func findingCaptureStarted() {
		detectionWasRunningBeforeCapture = ontheflyDetectionEnabled
		if ontheflyDetectionEnabled {
			snap.stopTimer()
		}
	}

	/// The finding-save dialog closed: resume only if detection was running before
	/// AND is still enabled (a background auto-pause may have turned it off meanwhile).
	/// `startTimer()` fires an immediate snapshot, so the frozen frame is replaced
	/// right away.
	func findingCaptureEnded() {
		// `mayCapture`, not `ontheflyDetectionEnabled`: a content process that died while the sheet
		// was open leaves the run interrupted, and restarting the timer here would resume capture
		// into the recovering document — the very thing the interruption exists to prevent
		// (AIA-0879). `webContentDidLoad()` restarts it once the replacement has loaded.
		if detectionWasRunningBeforeCapture && mayCapture {
			snap.startTimer(for: detectionRunID)
		}
		detectionWasRunningBeforeCapture = false
	}

	/// A driver registered while detection is active. Request a pass through the same run-scoped
	/// path as timer ticks instead of exposing SnapState's publisher to a view.
	func driverDidRegister() {
		guard mayCapture else { return }
		snap.requestSnapshot(for: detectionRunID)
	}

	/// The detection surface changed size after an active layout transition (for example PLAY
	/// hiding the browser chrome). The frame captured before that transition cannot be applied, so
	/// queue a fresh pass for the current run instead of waiting for the next timer cadence.
	func contentGeometryDidChange() {
		guard mayCapture else { return }
		snap.requestSnapshot(for: detectionRunID)
	}

	/// A web-content interaction finished. Its start invalidates the displayed frame and can discard
	/// an inference result that was already in flight; request a current-run replacement as soon as
	/// the content is stable instead of leaving the overlay empty until the next timer tick.
	func contentInteractionDidEnd() {
		guard mayCapture else { return }
		snap.requestSnapshot(for: detectionRunID)
	}

	/// The apply-time truth for a snapshot. This lives beside the lifecycle transitions so a
	/// SwiftUI mirror that has not rendered the most recent PLAY/PAUSE change cannot admit stale
	/// work by accident.
	func accepts(_ request: SnapshotRequest) -> Bool {
		mayCapture && request.runID == detectionRunID
	}

	/// Whether a snapshot may be requested or started right now.
	///
	/// One gate rather than a condition repeated at each call site, because the request paths below
	/// are exactly where a missed check does not fail loudly — it just captures a frame it should
	/// not have. Read at the apply-time boundary too (``accepts(_:)``), so a request enqueued before
	/// a termination cannot start a capture during the reload that follows it.
	private var mayCapture: Bool { ontheflyDetectionEnabled && isInterruptedByContentLoss.not }

	// MARK: - Web content process loss (AIA-0879)

	/// The web content process died under the detection run.
	///
	/// The first time a site does this the run is interrupted and resumes once the replacement
	/// document has loaded; a site that does it twice inside the policy window ends the run and
	/// leaves it ended. See ``WebContentTerminationPolicy`` for why it is not simply a stop.
	///
	/// Ending goes through ``ontheflyDetectionTapped(recordAnalytics:)`` rather than stopping the
	/// timer directly: leaving `ontheflyDetectionEnabled` true with a dead timer is a state the rest
	/// of this type does not model — the toolbar would show a run that is not running, and the
	/// user's next tap would read as "stop".
	///
	/// - Note: iOS also kills a backgrounded renderer, and the callback can arrive after the app is
	///   foregrounded again. Detection is off across a background (`MLBrowser` pauses it), so such a
	///   late callback finds no run to interrupt — but one that lands just after the foreground
	///   resume interrupts a run that had done nothing wrong. It costs one reload's worth of
	///   detection, which is why this is a note and not a guard.
	func webContentProcessDidTerminate(sequence: UInt64, host: String?, now: Date = Date()) {
		guard consumeWebContentEvent(sequence) else { return }
		guard ontheflyDetectionEnabled else { return }
		switch terminationPolicy.response(host: host, now: now) {
		case .endRun:
			LoggingPolicy.error(
				"Detection stopped: the web content process died twice here [site: \(host ?? "unknown")]",
				logger: .state
			)
			// Cleared first: `ontheflyDetectionTapped` clears it too, but only on the branch it
			// takes, and this must not depend on which that is.
			isInterruptedByContentLoss = false
			// `isUserInitiated: false`: the interruption is cleared above, and a stop the user did not
			// ask for must not refill the escalation budget of every OTHER site.
			ontheflyDetectionTapped(recordAnalytics: false, isUserInitiated: false)
		case .interrupt:
			LoggingPolicy.info(
				"Detection interrupted while the web view recovers [site: \(host ?? "unknown")]",
				logger: .state
			)
			isInterruptedByContentLoss = true
			snap.stopTimer()
		}
	}

	/// A document finished loading in the web view.
	///
	/// Resumes a run interrupted by ``webContentProcessDidTerminate(host:now:)``. Keyed on the
	/// interruption, so an ordinary page load — the overwhelming majority of calls — does nothing.
	///
	/// Deliberately the FINISHED signal rather than the commit: a commit means the main document
	/// arrived, which on the pages this was raised for is the start of the expensive part, not the
	/// end of it.
	func webContentDidLoad(sequence: UInt64) {
		guard consumeWebContentEvent(sequence) else { return }
		guard isInterruptedByContentLoss else { return }
		isInterruptedByContentLoss = false
		// The run can have ended meanwhile — a background pause, or the user stopping it while the
		// page reloaded. Clearing the interruption above is still right; starting a timer for a run
		// that is over is not.
		guard ontheflyDetectionEnabled else { return }
		snap.startTimer(for: detectionRunID)
	}

	/// The load stopped without producing a document, and nothing superseded it.
	///
	/// The interruption's whole job is to keep capture out of the memory peak of a page loading. A
	/// load that has stopped has no peak left to stay out of, so the run resumes on whatever is on
	/// screen — which is what the app did before this ticket, and is not worse than it.
	///
	/// Without this the interruption had no exit for a recovery the user cancelled: pressing Stop
	/// during the reload produced neither a finish nor a classified failure, so detection sat enabled
	/// and capturing nothing, with the toolbar showing a run and no way to tell it was over
	/// (raised in review). The site keeps its strike, so a second death still ends the run.
	func webContentDidStopLoading(sequence: UInt64) {
		guard consumeWebContentEvent(sequence) else { return }
		guard isInterruptedByContentLoss else { return }
		isInterruptedByContentLoss = false
		guard ontheflyDetectionEnabled else { return }
		LoggingPolicy.info("Detection resuming: the recovery load stopped without a document", logger: .state)
		snap.startTimer(for: detectionRunID)
	}

	/// Whether this event is new. Consumed regardless of the run's state, so a redelivery can never
	/// be answered twice. Sequence 0 means nothing has happened, which this rejects for free.
	private func consumeWebContentEvent(_ sequence: UInt64) -> Bool {
		guard sequence > lastAnsweredWebContentEvent else { return false }
		lastAnsweredWebContentEvent = sequence
		return true
	}

	/// The document that was replacing a dead renderer failed to load.
	///
	/// Ends the run instead of leaving it interrupted. Without this the interruption has no other
	/// way out: ``webContentDidLoad()`` is what clears it, and a page that never comes back never
	/// calls it — so detection would sit enabled, capturing nothing, with the toolbar showing a run
	/// and no way for the user to tell it was over but to press the button twice.
	///
	/// The caller is responsible for passing only genuine failures. A superseded load cancels with
	/// `NSURLErrorCancelled` on the ordinary path of navigating away, and ending a run on that would
	/// mean losing detection every time the user followed a link during a recovery.
	func webContentDidFailToLoad() {
		guard isInterruptedByContentLoss else { return }
		isInterruptedByContentLoss = false
		guard ontheflyDetectionEnabled else { return }
		LoggingPolicy.error(
			"Detection stopped: the page did not return after the web content process died",
			logger: .state
		)
		ontheflyDetectionTapped(recordAnalytics: false, isUserInitiated: false)
	}

	/// Applies a change of `settings.fullscreenDetection` to a running detection:
	/// enabling the feature enters fullscreen, disabling it restores the chrome.
	/// A no-op while detection is off (`chromeVisible` is already true then).
	func fullscreenDetectionSettingChanged() {
		guard ontheflyDetectionEnabled else { return }
		chromeVisible = settings.fullscreenDetection.not
	}
}
