//
//  UITestSupport.swift
//  MLBrowserUITests
//
//  Shared UI-test foundation for AIA-0189: deterministic launch, checkpoint reads,
//  page-object helpers. See ios/MLBrowserUITests/UI_TESTING_PLAN_AIA-0189.md.
//

import XCTest

// MARK: - Launch configuration

/// Black-box mirror of the app's `UITestLaunchConfiguration`
/// (`MLBrowser/iOS/Tools/Testability/UITestLaunchConfiguration.swift`). The app type is
/// not linked into the UI-test target, so the JSON contract is duplicated here — keep the
/// keys and `version` in sync with that file.
struct LaunchConfig: Encodable {
	enum PageScenario: String, Encodable {
		case home
		case blank
		case last
		case localFixture
	}

	var version = 10
	enum AnalyticsScenario: String, Encodable {
		case prompt
		case disabled
		case enabled
	}
	var startOnboardingTour: Bool?
	var pageScenario: PageScenario?
	var defaultPageOverride: String?
	var lastPage: String?
	var fullscreenDetection: Bool?
	var disableDetectionAnimations: Bool?
	var fixtureName: String?
	var stubDownloads: Bool?
	var enableClassifyDemo: Bool?
	var reviewFirstModelType: Bool?
	/// Keyed by `FeatureFlagKey.rawValue`; an unknown key traps in the app (AIA-0350).
	var featureFlagOverrides: [String: Bool]?
	var analyticsScenario: AnalyticsScenario?
	/// Raw JSON for the `appMessages` remote setting (AIA-0115). `nil` = no messages.
	var appMessagesJSON: String?
	/// Seed the free-access window as granted this many days ago (AIA-0556). `nil` = no anchor,
	/// i.e. a genuine first install. Every UI-test launch wipes its own storage, so this is the
	/// only way to reach the day-7 reminder or the expired wall.
	var freeAccessAnchorAgeDays: Int?
}

// MARK: - Accessibility identifiers

/// Identifiers mirrored from the app's `Testability` enum. The element name is the enum
/// case with its first letter capitalized (see `TestabilityIdentification`).
enum AID {
	// Checkpoints
	static let cpIntendedPageKind = "_AIA:Checkpoint.IntendedPageKind"
	static let cpSizeClass = "_AIA:Checkpoint.HorizontalSizeClass"
	static let cpFullscreen = "_AIA:Checkpoint.FullscreenFeatureEnabled"
	static let cpAppMode = "_AIA:Checkpoint.AppMode"
	static let cpDeviceIdiom = "_AIA:Checkpoint.DeviceIdiom"
	static let cpCurrentPageFile = "_AIA:Checkpoint.CurrentPageFile"
	static let cpDetectionCount = "_AIA:Checkpoint.DetectionCount"
	static let cpTiledBorderCount = "_AIA:Checkpoint.TiledBorderCount"
	static let cpDetectionFrameApplied = "_AIA:Checkpoint.DetectionFrameApplied"
	static let cpFlashCount = "_AIA:Checkpoint.FlashCount"
	static let cpClassificationCount = "_AIA:Checkpoint.ClassificationCount"
	static let cpTopClassification = "_AIA:Checkpoint.TopClassification"

	// Top toolbar (real Buttons)
	static let cpu = "_AIA:Button.GlobalToolbarSideMenu"
	static let address = "_AIA:Button.WebScreenAddressBar"
	static let addressClear = "_AIA:Button.WebScreenAddressClear"
	static let play = "_AIA:Button.GlobalToolbarPlayDetection"
	static let pause = "_AIA:Button.GlobalToolbarPauseDetection"
	static let edit = "_AIA:Button.GlobalToolbarAdjustments"
	static let findTop = "_AIA:Button.GlobalToolbarFind"
	static let webBack = "_AIA:Button.WebToolbarBack"
	static let webForward = "_AIA:Button.WebToolbarForward"
	static let webReload = "_AIA:Button.WebToolbarReload"

	// Floating capsule (compact only) — Images carrying the `.isButton` trait
	static let floatBack = "_AIA:Button.FloatingNavBack"
	static let floatForward = "_AIA:Button.FloatingNavForward"
	static let floatReload = "_AIA:Button.FloatingNavReload"
	static let floatFind = "_AIA:Button.FloatingNavFind"
	static let chromeToggle = "_AIA:Button.FloatingChromeToggle"

	// Drawer
	static let drawerSettings = "_AIA:Button.DrawerSettings"
	static let drawerFindings = "_AIA:Button.DrawerFindings"
	static let configEnabledToggle = "_AIA:Toggle.SideMenuCellEnabled"
	static let configDelete = "_AIA:Button.SideMenuDeleteConfiguration"
	static let configModelTypePicker = "_AIA:Picker.ConfigurationFormModelType"
	static let configFormDismiss = "_AIA:Button.ConfigurationFormDismiss"
	static let newConfigurationOpenCatalog = "_AIA:Button.NewConfigurationOpenCatalog"

	// Settings
	static let settingsDismiss = "_AIA:Button.SettingsDismiss"
	static let settingsShowLabels = "_AIA:Toggle.SettingsShowLabels"
	static let settingsRunAtLaunch = "_AIA:Toggle.SettingsRunAtLaunch"
	static let settingsTiledDetection = "_AIA:NavigationLink.SettingsTiledDetection"
	static let settingsPyramidTiling = "_AIA:Toggle.SettingsPyramidTiling"
	static let settingsGrid3x3Tiling = "_AIA:Toggle.SettingsGrid3x3Tiling"
	static let settingsTiledBorders = "_AIA:Toggle.SettingsTiledBorders"
	static let supportSettingsDetectScreenshots = "_AIA:Toggle.SupportSettingsDetectScreenshots"
	static let supportRequestIncludeApplicationLog = "_AIA:Toggle.SupportRequestIncludeApplicationLog"
	static let supportRequestSendUnredactedData = "_AIA:Toggle.SupportRequestSendUnredactedData"
	static let settingsFullscreenDetection = "_AIA:Toggle.SettingsFullscreenDetection"
	static let settingsDisableDetectionAnimations = "_AIA:Toggle.SettingsDisableDetectionAnimations"
	static let settingsAnalytics = "_AIA:Toggle.SettingsAnalytics"
	static let settingsReopenLastPage = "_AIA:Toggle.SettingsReopenLastPage"
	static let settingsFrequency = "_AIA:Picker.SettingsFrequency"
	static let settingsDefaultPage = "_AIA:TextField.SettingsDefaultPage"
	static let settingsHistoryLimit = "_AIA:TextField.SettingsHistoryLimit"
	static let settingsHistory = "_AIA:NavigationLink.SettingsHistory"
	static let settingsAbout = "_AIA:NavigationLink.SettingsAbout"
	static let settingsReset = "_AIA:NavigationLink.SettingsReset"
	static let settingsReplayOnboarding = "_AIA:Button.SettingsReplayOnboarding"
	static let settingsDeleteCache = "_AIA:Button.SettingsDeleteCache"
	static let settingsRestoreDefaults = "_AIA:Button.SettingsRestoreDefaults"
	// AIA-0303: Settings → Reset → Remove Findings (row, export-first action, delete confirm)
	static let settingsRemoveFindings = "_AIA:Button.SettingsRemoveFindings"
	static let settingsRemoveFindingsExport = "_AIA:Button.SettingsRemoveFindingsExport"
	static let settingsRemoveFindingsConfirm = "_AIA:Button.SettingsRemoveFindingsConfirm"
	static let supportSettingsSendEmail = "_AIA:Button.SupportSettingsSendEmail"
	static let appDescriptionReportProblem = "_AIA:NavigationLink.AppDescriptionReportProblem"

	// Browsing history
	static let historyClear = "_AIA:Button.BrowsingHistoryClear"   // also anchors the screen's presence
	static let historyDeleteEntry = "_AIA:Button.BrowsingHistoryDeleteEntry"
	static let historyItem = "_AIA:Label.BrowsingHistoryItem"
	static let configDescription = "_AIA:Label.SideMenuCellDescription"

	// Onboarding tour (AIA-0333)
	static let tourBubble = "_AIA:View.TourBubble"
	static let tourSkip = "_AIA:Button.TourSkip"
	static let tourNext = "_AIA:Button.TourNext"
	static let cpTourStep = "_AIA:Checkpoint.TourStep"

	// Save-finding sheet (AIA-0333 capture step)
	static let saveFindingTitle = "_AIA:TextField.SaveFindingTitle"
	static let saveFindingSave = "_AIA:Button.SaveFindingSave"

	// Auth gate (AIA-0340)
	static let authSignIn = "_AIA:Button.AuthSignIn"
	static let drawerSignIn = "_AIA:Button.DrawerSignIn"
	static let drawerAccount = "_AIA:Button.DrawerAccount"
	static let drawerAccountOffline = "_AIA:Label.DrawerAccountOffline"
	static let settingsAccountOffline = "_AIA:Label.SettingsAccountOffline"
	static let settingsSignIn = "_AIA:Button.SettingsSignIn"
	static let authOfflineRetry = "_AIA:Button.AuthOfflineRetry"
	static let analyticsChoiceEnable = "_AIA:Button.AnalyticsChoiceEnable"
	static let analyticsChoiceNotNow = "_AIA:Button.AnalyticsChoiceNotNow"

	// Subscription paywall (AIA-0343)
	static let paywallSubscribe = "_AIA:Button.PaywallSubscribe"
	static let paywallRestore = "_AIA:Button.PaywallRestore"
	static let paywallSignIn = "_AIA:Button.PaywallSignIn"
	static let paywallSignOut = "_AIA:Button.PaywallSignOut"
	static let paywallDeleteAccount = "_AIA:Button.PaywallDeleteAccount"
	static let paywallDeleteAccountConfirm = "_AIA:Button.PaywallDeleteAccountConfirm"

	// Free-access window (AIA-0556). `paywallContinue` and the headline exist only on the two
	// informational presentations, so their absence is itself the proof that the hard wall is showing.
	static let paywallContinue = "_AIA:Button.PaywallContinue"
	static let paywallFreeAccessHeadline = "_AIA:Label.PaywallFreeAccessHeadline"
	static let settingsUpgrade = "_AIA:Button.SettingsUpgrade"

	// App Messages (AIA-0115). The banner container, its title, and the informational dismiss carry
	// bare identifiers; the reply buttons and About rows carry a `label:` (the button id / message
	// id), which `TestabilityIdentification.callAsFunction` renders as `#<label>` *before* the element
	// name (e.g. `_AIA:Button.#yesAppMessageReply`).
	static let appMessageBanner = "_AIA:View.AppMessageBanner"
	static let appMessageTitle = "_AIA:Label.AppMessageTitle"
	static let appMessageDismiss = "_AIA:Button.AppMessageDismiss"
	static func appMessageReply(_ buttonID: String) -> String { "_AIA:Button.#\(buttonID)AppMessageReply" }
	static func appMessageAboutRow(_ messageID: String) -> String { "_AIA:Label.#\(messageID)AppMessageAboutRow" }
	static func appMessageSettingsRow(_ messageID: String) -> String { "_AIA:Label.#\(messageID)AppMessageSettingsRow" }

	// Location / address sheet
	static let locationInput = "_AIA:TextField.LocationSheetInput"
	static let locationDismiss = "_AIA:Button.LocationSheetDismiss"
	static let locationHistoryItem = "_AIA:Button.LocationSheetHistoryItem"
	static let locationFullUrls = "_AIA:Button.LocationSheetFullUrls"
}

// MARK: - Base case

/// Base class for ML Browser UI tests. Subclasses call `launch(...)` and use the helpers
/// below. Orientation is reset to portrait around every test so rotation never leaks into
/// the next one.
///
/// `@MainActor`: UI testing drives `XCUIApplication`/`XCUIElement`/`XCUIDevice`, which are
/// main-actor isolated, so the whole case runs on the main actor (Apple's recommended
/// pattern). This also clears the Swift 6 isolation warnings the helpers would otherwise emit.
@MainActor
class UITestCase: XCTestCase {

	var app: XCUIApplication!

	// Async setUp/tearDown (not the `…WithError` overrides) so they inherit the class's
	// `@MainActor` isolation — the `…WithError` variants override nonisolated XCTestCase
	// methods and would stay nonisolated, re-introducing the Swift 6 isolation warnings.
	override func setUp() async throws {
		try await super.setUp()
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
	}

	override func tearDown() async throws {
		XCUIDevice.shared.orientation = .portrait
		app = nil
		try await super.tearDown()
	}

	/// Launches the app with a deterministic configuration. The default config applies the
	/// baseline only (wizard skipped, detection off, home page = about:blank).
	@discardableResult
	func launch(
		_ config: LaunchConfig = LaunchConfig(),
		mockAuthGate: String? = nil,
		mockSubscription: String? = nil,
		mockAccountID: String? = nil
	) -> XCUIApplication {
		let app = XCUIApplication()
		app.launchEnvironment["UI_TESTING"] = "1"
		// swiftlint:disable:next force_try
		let data = try! JSONEncoder().encode(config)
		app.launchEnvironment["UI_TEST_CONFIG"] = String(data: data, encoding: .utf8)
		// Pin locale so toolbar order is never reversed by RTL / localization.
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
		// AIA-0340: drive the auth gate's DEBUG mock provider to a specific state.
		// Default (nil) resolves to `.ready`, so existing tests bypass the gate.
		if let mockAuthGate {
			app.launchArguments += ["-mockAuthGate", mockAuthGate]
		}
		// AIA-0343: drive the subscription gate's DEBUG mock. Default (nil) resolves to
		// `.subscribed`, so existing tests pass straight through the whole-app gate.
		if let mockSubscription {
			app.launchArguments += ["-mockSubscription", mockSubscription]
		}
		// AIA-0437: choose which account the mock auth provider reports, so a test can drive the
		// account-scoped analytics choice across a switch. Default (nil) keeps the mock's own
		// stable account, so every existing test sees the same person on every launch.
		if let mockAccountID {
			app.launchArguments += ["-mockAccountID", mockAccountID]
		}
		app.launch()
		self.app = app
		return app
	}

	// MARK: Checkpoints

	private func checkpoint(_ id: String) -> XCUIElement { app.staticTexts[id] }

	/// Waits until the named checkpoint reports `expected`. Asserts on the value, not mere
	/// existence — the element can appear before its state settles.
	@discardableResult
	func waitForCheckpoint(_ id: String, equals expected: String, timeout: TimeInterval = 10) -> Bool {
		let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
		let expectation = XCTNSPredicateExpectation(predicate: predicate, object: checkpoint(id))
		return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
	}

	func checkpointValue(_ id: String, timeout: TimeInterval = 10) -> String? {
		let element = checkpoint(id)
		guard element.waitForExistence(timeout: timeout) else { return nil }
		return (element.value as? String) ?? element.label
	}

	/// The active horizontal size class, read from the in-app checkpoint.
	var isRegularWidth: Bool { checkpointValue(AID.cpSizeClass) == "regular" }

	/// The device idiom, read from the in-app checkpoint. Drives the chrome-composition
	/// assertions (iPhone uses the capsule; iPad/Mac put navigation in the top bar).
	var isPhoneIdiom: Bool { checkpointValue(AID.cpDeviceIdiom) == "phone" }

	/// Waits until the app window reports landscape dimensions, so geometry-based
	/// assertions run only after a rotation has actually re-laid out. The size-class and
	/// idiom checkpoints don't change on iPhone rotation, so they can't serve as the
	/// settle signal — the window aspect can.
	@discardableResult
	func waitForLandscape(timeout: TimeInterval = 10) -> Bool {
		let isLandscape = NSPredicate { object, _ in
			guard let window = object as? XCUIElement else { return false }
			let frame = window.frame
			return frame.width > frame.height
		}
		let expectation = XCTNSPredicateExpectation(predicate: isLandscape, object: app.windows.firstMatch)
		return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
	}

	// MARK: Layout assertions

	/// Asserts the listed button identifiers exist (non-zero width) and are laid out
	/// strictly left-to-right by `frame.minX`, in the order given.
	func assertButtonsLeftToRight(
		_ ids: [String],
		timeout: TimeInterval = 10,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		var previousMinX = -Double.greatestFiniteMagnitude
		for id in ids {
			let element = app.buttons[id]
			XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing button \(id)", file: file, line: line)
			let frame = element.frame
			XCTAssertGreaterThan(frame.width, 0, "\(id) has zero width", file: file, line: line)
			XCTAssertGreaterThan(
				Double(frame.minX), previousMinX,
				"\(id) is not to the right of the previous element", file: file, line: line
			)
			previousMinX = Double(frame.minX)
		}
	}

	/// Asserts an element (any type) is present or absent.
	func assertExists(
		_ id: String,
		_ shouldExist: Bool,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let element = app.descendants(matching: .any)[id]
		if shouldExist {
			XCTAssertTrue(element.waitForExistence(timeout: 10), "Expected \(id) to exist", file: file, line: line)
		} else {
			XCTAssertFalse(element.waitForExistence(timeout: 2), "Expected \(id) to be absent", file: file, line: line)
		}
	}

	/// Waits for an element to disappear.
	@discardableResult
	func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
		let predicate = NSPredicate(format: "exists == false")
		let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
		return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
	}

	// MARK: Navigation helpers

	/// Opens the left drawer (side menu) and waits for it to appear.
	func openDrawer(file: StaticString = #filePath, line: UInt = #line) {
		let menu = app.buttons[AID.cpu]
		XCTAssertTrue(menu.waitForExistence(timeout: 10), "Side-menu button missing", file: file, line: line)
		menu.tap()
		XCTAssertTrue(app.buttons[AID.drawerSettings].waitForExistence(timeout: 10), "Drawer did not open", file: file, line: line)
	}

	/// Opens the drawer and taps through to the Settings sheet.
	///
	/// The drawer→sheet transition occasionally drops the first tap on a slow CI runner (the tap
	/// lands while the drawer is still animating), leaving the sheet unopened — a flake seen as
	/// "Settings sheet did not appear". Guard against it: wait for the entry to be hittable (not
	/// just present) before tapping, and retry the tap once if the sheet hasn't appeared.
	func openSettings(file: StaticString = #filePath, line: UInt = #line) {
		openDrawer(file: file, line: line)
		let settings = app.buttons[AID.drawerSettings]
		let dismiss = app.buttons[AID.settingsDismiss]
		for _ in 0..<2 {
			let hittablePredicate = NSPredicate(format: "exists == true && hittable == true")
			let hittableExpectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: settings)
			_ = XCTWaiter().wait(for: [hittableExpectation], timeout: 8)
			if settings.isHittable {
				settings.tap()
			}
			if dismiss.waitForExistence(timeout: 8) {
				return
			}
		}
		XCTAssertTrue(dismiss.exists, "Settings sheet did not appear", file: file, line: line)
	}

	/// Waits for demo data to finish seeding, signalled by the first configuration toggle
	/// appearing in the open drawer. Seeding is async (real CoreML metadata extraction), so the
	/// timeout is generous. Call with the drawer already open.
	@discardableResult
	func waitForSeededConfigurations(timeout: TimeInterval = 20) -> Bool {
		app.switches.matching(identifier: AID.configEnabledToggle).firstMatch.waitForExistence(timeout: timeout)
	}

	/// An element of any type by identifier (SwiftUI maps `accessibilityIdentifier` onto a
	/// range of underlying element types, so `app.buttons[...]` alone is too narrow).
	func element(_ id: String) -> XCUIElement {
		app.descendants(matching: .any)[id]
	}

	/// Scrolls the screen (swiping up) until the identified element exists, capped at
	/// `maxSwipes`. SwiftUI `Form`/`List` realize off-screen rows lazily, so an element below
	/// the fold may not exist until scrolled toward.
	///
	/// Precondition: only scrolls *down* (content up). Callers that scroll to several elements
	/// must request them in top-to-bottom order; this helper cannot return to an element already
	/// scrolled past. Swiping up never triggers a sheet's interactive (downward) dismiss.
	@discardableResult
	func scrollTo(_ id: String, maxSwipes: Int = 8) -> Bool {
		let target = element(id)
		var swipes = 0
		while target.exists == false && swipes < maxSwipes {
			app.swipeUp()
			swipes += 1
		}
		return target.exists
	}

	/// Taps a switch by identifier and asserts its value flips. Returns false if the switch is
	/// missing or the value did not change.
	@discardableResult
	func flipSwitch(_ id: String, timeout: TimeInterval = 10) -> Bool {
		let toggle = app.switches.matching(identifier: id).firstMatch
		guard toggle.waitForExistence(timeout: timeout) else { return false }
		let before = (toggle.value as? String) ?? ""
		let flipped = NSPredicate(format: "value != %@", before)

		// A `.labelsHidden()` Toggle (e.g. the drawer cell) is a control-only element, so a plain
		// tap flips it. A labelled Form Toggle's accessibility element spans the whole row, so a
		// center tap lands on the label and no-ops — fall back to tapping the trailing edge where
		// the switch control sits. Trying the plain tap first keeps this resilient to a row
		// gaining a trailing accessory that would shift the control off the 0.9 fraction.
		toggle.tap()
		if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: 2) == .completed {
			return true
		}
		toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
		return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: 5) == .completed
	}
}
