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
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Detection reset tapped enabled=\(ontheflyDetectionEnabled) timerActive=\(snap.timerCancellable != nil)",
			logger: .state
		)
		if ontheflyDetectionEnabled {
			snap.stopTimer()
			snap.startTimer()
		}
	}

	func ontheflyDetectionTapped(recordAnalytics: Bool = true) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Detection toggle tapped before enabled=\(ontheflyDetectionEnabled) chromeVisible=\(chromeVisible) fullscreenSetting=\(settings.fullscreenDetection) timerActive=\(snap.timerCancellable != nil)",
			logger: .state
		)
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			chromeVisible = settings.fullscreenDetection.not
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] Detection enabled; chromeVisible=\(chromeVisible) fullscreen=\(isFullscreen); starting timer",
				logger: .state
			)
			snap.startTimer()
			if recordAnalytics {
				analytics?.recordDetectionRun()
			}
		} else {
			chromeVisible = true
			// An open adjustment overlay would be orphaned once its toolbar
			// button disappears with detection mode.
			showSnapAdjustment = false
			snap.stopTimer()
		}
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Detection toggle completed enabled=\(ontheflyDetectionEnabled) chromeVisible=\(chromeVisible) timerActive=\(snap.timerCancellable != nil)",
			logger: .state
		)
	}

	func chromeToggleTapped() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Chrome toggle tapped before visible=\(chromeVisible) detectionEnabled=\(ontheflyDetectionEnabled)",
			logger: .state
		)
		chromeVisible.toggle()
		LoggingPolicy.debug("[AIA-0587 TRACE] Chrome visibility changed to \(chromeVisible)", logger: .state)
	}

	/// Detection was running when the finding-save dialog opened; only then does
	/// ending the capture resume the timer.
	private var detectionWasRunningBeforeCapture = false

	/// A finding-save dialog opened: stop the snapshot timer so no new passes start.
	/// Only the timer is owned here — the displayed-frame freeze (generation bump,
	/// queue cancellation, apply gating) lives in DetectableView, which owns that state.
	func findingCaptureStarted() {
		detectionWasRunningBeforeCapture = ontheflyDetectionEnabled
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Finding capture started detectionEnabled=\(ontheflyDetectionEnabled)",
			logger: .state
		)
		if ontheflyDetectionEnabled {
			snap.stopTimer()
		}
	}

	/// The finding-save dialog closed: resume only if detection was running before
	/// AND is still enabled (a background auto-pause may have turned it off meanwhile).
	/// `startTimer()` fires an immediate snapshot, so the frozen frame is replaced
	/// right away.
	func findingCaptureEnded() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Finding capture ended wasRunning=\(detectionWasRunningBeforeCapture) enabledNow=\(ontheflyDetectionEnabled)",
			logger: .state
		)
		if detectionWasRunningBeforeCapture && ontheflyDetectionEnabled {
			snap.startTimer()
		}
		detectionWasRunningBeforeCapture = false
	}

	/// Applies a change of `settings.fullscreenDetection` to a running detection:
	/// enabling the feature enters fullscreen, disabling it restores the chrome.
	/// A no-op while detection is off (`chromeVisible` is already true then).
	func fullscreenDetectionSettingChanged() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] Fullscreen setting changed enabled=\(ontheflyDetectionEnabled) setting=\(settings.fullscreenDetection)",
			logger: .state
		)
		guard ontheflyDetectionEnabled else {
			LoggingPolicy.debug("[AIA-0587 TRACE] Fullscreen setting change ignored while detection is paused", logger: .state)
			return
		}
		chromeVisible = settings.fullscreenDetection.not
		LoggingPolicy.debug("[AIA-0587 TRACE] Fullscreen setting applied chromeVisible=\(chromeVisible)", logger: .state)
	}
}
