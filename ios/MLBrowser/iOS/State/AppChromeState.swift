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

	/// Whether the web screen is in finding-pick mode: the user is aiming the crosshair at the
	/// place to store. Durable state rather than the transient request pulse this replaced
	/// (AIA-0880), because the Find/Store control now has to *read* the mode to cancel it, and
	/// because a pulse reset inline from an `onReceive` closure latches — `@Published` publishes
	/// from `willSet`, so the outer assignment writes the reset back over itself (measured in
	/// AIA-0657; see the `pageToOpen` comment in WebScreen).
	///
	/// WebScreen owns the transitions and mirrors them into its own `@State`. The invariant that
	/// keeps the `willSet` hazard closed: WebScreen sets its local copy *before* calling
	/// `findPickEnded()`, and never writes back from the `true` branch — so no nested write ever
	/// contradicts an assignment still in flight.
	@Published private(set) var findPickActive: Bool = false

	/// The Find/Store button (top bar on regular widths, floating capsule on compact) was tapped.
	/// It both starts pick mode and cancels the pick in progress, so a user who opened it by
	/// accident can back out with the same control they opened it with (AIA-0880).
	///
	/// - Parameter allowsCancel: `false` for callers that cannot recover from a cancel. The guided
	///   tour drives this control itself and its pick-mode step, once fulfilled, does not re-arm.
	func findTapped(allowsCancel: Bool = true) {
		findPickActive = (findPickActive && allowsCancel) ? false : true
	}

	/// WebScreen left pick mode for its own reasons — the capture was presented, or the screen was
	/// torn down. Not a user cancel; it only brings this state back in step with the web screen.
	func findPickEnded() {
		findPickActive = false
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
