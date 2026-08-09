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
			snap.startTimer(for: detectionRunID)
		}
	}

	func ontheflyDetectionTapped(recordAnalytics: Bool = true) {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			detectionRunID &+= 1
			chromeVisible = settings.fullscreenDetection.not
			snap.startTimer(for: detectionRunID)
			if recordAnalytics {
				analytics?.recordDetectionRun()
			}
		} else {
			detectionRunID &+= 1
			chromeVisible = true
			// An open adjustment overlay would be orphaned once its toolbar
			// button disappears with detection mode.
			showSnapAdjustment = false
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
		if detectionWasRunningBeforeCapture && ontheflyDetectionEnabled {
			snap.startTimer(for: detectionRunID)
		}
		detectionWasRunningBeforeCapture = false
	}

	/// A driver registered while detection is active. Request a pass through the same run-scoped
	/// path as timer ticks instead of exposing SnapState's publisher to a view.
	func driverDidRegister() {
		guard ontheflyDetectionEnabled else { return }
		snap.requestSnapshot(for: detectionRunID)
	}

	/// The apply-time truth for a snapshot. This lives beside the lifecycle transitions so a
	/// SwiftUI mirror that has not rendered the most recent PLAY/PAUSE change cannot admit stale
	/// work by accident.
	func accepts(_ request: SnapshotRequest) -> Bool {
		ontheflyDetectionEnabled && request.runID == detectionRunID
	}

	/// Applies a change of `settings.fullscreenDetection` to a running detection:
	/// enabling the feature enters fullscreen, disabling it restores the chrome.
	/// A no-op while detection is off (`chromeVisible` is already true then).
	func fullscreenDetectionSettingChanged() {
		guard ontheflyDetectionEnabled else { return }
		chromeVisible = settings.fullscreenDetection.not
	}
}
