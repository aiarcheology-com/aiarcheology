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

	/// The drawer's sheets, shared by the drawer view and headless mode (AIA-0984).
	let drawerPresentation = DrawerPresentation()
	/// The web screen's save-finding sheet, shared by the web screen and headless mode (AIA-0984).
	let saveFindingPresentation = SaveFindingPresentation()

	@Published var mode = AppMode.web
	/// Whether the drawer is open. Every path that closes it — the drawer's own controls through
	/// ContentView's bridge, a direct write, `togglingSideMenu()` — ends in this property, so this is
	/// where the drawer's sheets are dismissed. `DrawerContent` unmounts when the drawer closes, which
	/// used to drop the `@State` those sheets were bound to; the shared model must be reset instead.
	/// A `didSet` rather than a Combine sink: `@Published` publishes from `willSet`, so a subscriber
	/// would run before the new value is stored (see `findPickActive`). Dismissing mutates the
	/// `@Observable` model, not a `@Published` property, so no nested publish can write back.
	@Published var presentedSideMenu: Bool = false {
		didSet {
			if presentedSideMenu == false {
				drawerPresentation.dismissSheets()
			}
		}
	}
	@Published var selectedConfigurationId: UUID?
	@Published var pageToOpen: URL?
	/// A request to put the findings inventory on screen (AIA-0650), set alongside
	/// ``presentedSideMenu`` and consumed (reset to `false`) by `DrawerContent` when it appears. It
	/// was a *latch* because the presenting flag was `@State` inside a view that did not exist yet
	/// when the request was made. That flag now lives in ``drawerPresentation`` (AIA-0984), which
	/// outlives the view; whether the latch is still needed is left to a separate change.
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
