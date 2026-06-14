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

	static func slide(_ index: Int) -> String { "_AIA:View.SlideshowSlide#\(index)" }
}

// MARK: - Base case

/// Base class for ML Browser UI tests. Subclasses call `launch(...)` and use the helpers
/// below. Orientation is reset to portrait around every test so rotation never leaks into
/// the next one.
class UITestCase: XCTestCase {

	var app: XCUIApplication!

	override func setUpWithError() throws {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
	}

	override func tearDownWithError() throws {
		XCUIDevice.shared.orientation = .portrait
		app = nil
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
}
