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
	@Published var presentSettings: Bool = false
	@Published var pageToOpen: URL?
	@Published var addressBarMenu: [URL] = []
	@Published var addressSelected: URL?
	@Published var contentInteractionState: ContentInteractionState = .idle
	@Published var showSnapAdjustment: Bool = false
	/// Whether the browser chrome (navigation bar with address field and buttons) is visible.
	/// Only meaningful while `ontheflyDetectionEnabled` is true; always reset to `true`
	/// when detection stops. Uniform rule: every detection start hides chrome, every stop
	/// shows it — regardless of initiator (user tap, auto-start, background/foreground
	/// cycle, application reset). Views mutate it via `chromeToggleTapped()`.
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
	/// regardless of whether the chrome is currently revealed.
	var showsFloatingChromeButton: Bool { ontheflyDetectionEnabled }

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}

    @MainActor func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			snap.stopTimer()
			snap.startTimer()
		}
	}

	func historySelected(_ item: URL) {
		addressSelected = item
		addressBarMenu = []
	}

    @MainActor func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			chromeVisible = false
			snap.startTimer()
		} else {
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

	func settingsTapped() {
		presentSettings = true
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
