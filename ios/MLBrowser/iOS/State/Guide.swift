//
//  Guide.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

final class Guide: ObservableObject {
	var snap: SnapState
    var deep: DeepState
    var settings: Settings
    unowned var snapAdjustment: SnapAdjustment
    let dataController: DataController
    let demoDataManager: DemoDataManager
    
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var pageToOpen: URL?
	@Published var contentInteractionState: ContentInteractionState = .idle
	@Published var showSnapAdjustment: Bool = false
	/// Whether the browser chrome (navigation bar with address field and buttons) is visible.
	/// Only meaningful while `ontheflyDetectionEnabled` is true; always reset to `true`
	/// when detection stops. Uniform rule: every detection start hides chrome (provided
	/// `settings.fullscreenDetection` is enabled), every stop shows it — regardless of
	/// initiator (user tap, auto-start, background/foreground cycle, application reset).
	/// Views mutate it via `chromeToggleTapped()`.
	@Published private(set) var chromeVisible: Bool = true

	init(snap: SnapState, deep: DeepState, settings: Settings, dataController: DataController, demoDataManager: DemoDataManager, snapAdjustment: SnapAdjustment) {
		self.snap = snap
        self.deep = deep
        self.settings = settings
        self.dataController = dataController
        self.demoDataManager = demoDataManager
        self.snapAdjustment = snapAdjustment
	}

	/// Fullscreen = detection running and chrome hidden (the default while detecting).
	var isFullscreen: Bool { ontheflyDetectionEnabled && chromeVisible.not }

	/// The floating chrome-toggle button accompanies detection for its whole duration,
	/// regardless of whether the chrome is currently revealed — but only when the
	/// fullscreen feature is enabled in Settings.
	@MainActor var showsFloatingChromeButton: Bool { ontheflyDetectionEnabled && settings.fullscreenDetection }

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}

    @MainActor func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			snap.stopTimer()
			snap.startTimer()
		}
	}

    @MainActor func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			chromeVisible = settings.fullscreenDetection.not
			snap.startTimer()
		} else {
			chromeVisible = true
			// An open adjustment overlay would be orphaned once its toolbar
			// button disappears with detection mode.
			showSnapAdjustment = false
			snap.stopTimer()
		}
	}

	@MainActor func chromeToggleTapped() {
		chromeVisible.toggle()
	}

	/// Detection was running when the finding-save dialog opened; only then does
	/// ending the capture resume the timer.
	private var detectionWasRunningBeforeCapture = false

	/// A finding-save dialog opened: stop the snapshot timer so no new passes start.
	/// Only the timer is owned here — the displayed-frame freeze (generation bump,
	/// queue cancellation, apply gating) lives in DetectableView, which owns that state.
	@MainActor func findingCaptureStarted() {
		detectionWasRunningBeforeCapture = ontheflyDetectionEnabled
		if ontheflyDetectionEnabled {
			snap.stopTimer()
		}
	}

	/// The finding-save dialog closed: resume only if detection was running before
	/// AND is still enabled (a background auto-pause may have turned it off meanwhile).
	/// `startTimer()` fires an immediate snapshot, so the frozen frame is replaced
	/// right away.
	@MainActor func findingCaptureEnded() {
		if detectionWasRunningBeforeCapture && ontheflyDetectionEnabled {
			snap.startTimer()
		}
		detectionWasRunningBeforeCapture = false
	}

	/// Applies a change of `settings.fullscreenDetection` to a running detection:
	/// enabling the feature enters fullscreen, disabling it restores the chrome.
	/// A no-op while detection is off (`chromeVisible` is already true then).
	@MainActor func fullscreenDetectionSettingChanged() {
		guard ontheflyDetectionEnabled else { return }
		chromeVisible = settings.fullscreenDetection.not
	}

    @MainActor func resetApplication() async {
		if ontheflyDetectionEnabled {
			ontheflyDetectionTapped()
		}
		await deep.reset()
		settings.reset()
		settings.applicationResetButtonToggle.toggle()
		await demoDataManager.deleteBrowsingHistory()
		await demoDataManager.createDemoDataIfNeeded()
	}
}
