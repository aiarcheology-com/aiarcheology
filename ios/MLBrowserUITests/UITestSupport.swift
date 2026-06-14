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
	}

	var version = 1
	var presentWizard: Bool?
	var pageScenario: PageScenario?
	var defaultPageOverride: String?
	var lastPage: String?
	var fullscreenDetection: Bool?
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

	// Top toolbar (real Buttons)
	static let cpu = "_AIA:Button.GlobalToolbarSideMenu"
	static let address = "_AIA:Button.WebScreenAddressBar"
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

	// Settings
	static let settingsDismiss = "_AIA:Button.SettingsDismiss"
	static let settingsShowLabels = "_AIA:Toggle.SettingsShowLabels"
	static let settingsRunAtLaunch = "_AIA:Toggle.SettingsRunAtLaunch"
	static let settingsTiledDetection = "_AIA:Toggle.SettingsTiledDetection"
	static let settingsFullscreenDetection = "_AIA:Toggle.SettingsFullscreenDetection"
	static let settingsReopenLastPage = "_AIA:Toggle.SettingsReopenLastPage"
	static let settingsFrequency = "_AIA:Picker.SettingsFrequency"
	static let settingsDefaultPage = "_AIA:TextField.SettingsDefaultPage"
	static let settingsHistoryLimit = "_AIA:TextField.SettingsHistoryLimit"
	static let settingsHistory = "_AIA:NavigationLink.SettingsHistory"
	static let settingsAbout = "_AIA:NavigationLink.SettingsAbout"
	static let settingsIntroduction = "_AIA:NavigationLink.SettingsIntroduction"
	static let settingsDeleteCache = "_AIA:Button.SettingsDeleteCache"
	static let settingsRestoreDefaults = "_AIA:Button.SettingsRestoreDefaults"

	// Browsing history
	static let historyTitle = "Browsing History"   // navigation-bar title (anchors the screen)
	static let historyClear = "_AIA:Button.BrowsingHistoryClear"
	static let historyDeleteEntry = "_AIA:Button.BrowsingHistoryDeleteEntry"
	static let historyItem = "_AIA:Label.BrowsingHistoryItem"
	static let configDescription = "_AIA:Label.SideMenuCellDescription"

	// Location / address sheet
	static let locationInput = "_AIA:TextField.LocationSheetInput"
	static let locationDismiss = "_AIA:Button.LocationSheetDismiss"
	static let locationHistoryItem = "_AIA:Button.LocationSheetHistoryItem"
	static let locationFullUrls = "_AIA:Button.LocationSheetFullUrls"

	static func slide(_ index: Int) -> String { "_AIA:View.SlideshowSlide#\(index)" }
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
	func launch(_ config: LaunchConfig = LaunchConfig()) -> XCUIApplication {
		let app = XCUIApplication()
		app.launchEnvironment["UI_TESTING"] = "1"
		// swiftlint:disable:next force_try
		let data = try! JSONEncoder().encode(config)
		app.launchEnvironment["UI_TEST_CONFIG"] = String(data: data, encoding: .utf8)
		// Pin locale so toolbar order is never reversed by RTL / localization.
		app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
	func openSettings(file: StaticString = #filePath, line: UInt = #line) {
		openDrawer(file: file, line: line)
		app.buttons[AID.drawerSettings].tap()
		XCTAssertTrue(
			app.buttons[AID.settingsDismiss].waitForExistence(timeout: 10),
			"Settings sheet did not appear", file: file, line: line
		)
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
