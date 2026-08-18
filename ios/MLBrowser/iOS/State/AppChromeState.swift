//
//  AppChromeState.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//  AIA-0391: renamed from `Guide` and slimmed to app-chrome + navigation state. The detection
//  session lifecycle (and the snapshot-timer commanding) moved to the sibling
//  `DetectionSessionState`; this type holds the drawer/mode chrome and page-navigation intents.
//

import Foundation

@MainActor
final class AppChromeState: ObservableObject {
	let deep: DeepState
	let settings: Settings
	let demoDataManager: DemoDataManager
	private let analytics: AnalyticsState?
	/// Whole-app reset first stops any running detection, so chrome state borrows the detection
	/// controller. Chrome → detection is one-directional (detection never references chrome).
	let detectionState: DetectionSessionState

	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var pageToOpen: URL?
	/// A request to put the findings inventory on screen (AIA-0650). The sheet itself is owned by
	/// `DrawerContent`, which is only mounted while the drawer is open — so this is a *latch*, set
	/// alongside ``presentedSideMenu`` and consumed (reset to `false`) by `DrawerContent` when it
	/// appears. A plain call is impossible: the presenting `@State` lives inside a view that does not
	/// exist yet at the moment the request is made.
	@Published var presentsFindings: Bool = false
	/// Write-only today (set by WebScreen; no reader) — retained as-is, out of scope to remove.
	@Published var contentInteractionState: ContentInteractionState = .idle

	init(
		detectionState: DetectionSessionState,
		deep: DeepState,
		settings: Settings,
		demoDataManager: DemoDataManager,
		analytics: AnalyticsState? = nil
	) {
		self.detectionState = detectionState
		self.deep = deep
		self.settings = settings
		self.demoDataManager = demoDataManager
		self.analytics = analytics
	}

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}

	/// The Find/Store button (top bar on regular widths, floating capsule on
	/// compact) was tapped: the web screen enters pick mode — the next tap on the
	/// content marks the place to store. Consumed and reset by WebScreen.
	@Published var findModeRequested: Bool = false

	func findTapped() {
		findModeRequested = true
	}

	/// Whole-app reset: stop any running detection, then wipe derived/demo data and settings.
	func resetApplication() async {
		if detectionState.ontheflyDetectionEnabled {
			detectionState.ontheflyDetectionTapped()
		}
		await deep.reset()
		analytics?.resetAnalyticsChoice()
		settings.reset()
		settings.applicationResetButtonToggle.toggle()
		await demoDataManager.deleteBrowsingHistory()
		await demoDataManager.createDemoDataIfNeeded()
	}
}
