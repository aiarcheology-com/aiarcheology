//
//  ReceivedFindingsUITests.swift
//  MLBrowserUITests
//
//  AIA-0835: a finding arriving by deeplink is stored, listed under Received, and read-only.
//
//  These cover what the unit tests structurally cannot: that the link actually reaches the store
//  through the real `onOpenURL` path, that the row lands in the right tab, and that "read-only" is
//  true where the user taps rather than only where the flag is read.
//

import XCTest

final class ReceivedFindingsUITests: UITestCase {

	/// A link the app will accept: `FindingShareLink`'s own host and path, a version and a title.
	/// Built here rather than borrowed from the app so a change to the wire format that breaks
	/// recipients shows up as a failing test instead of a silently-still-passing one.
	private func link(id: String, title: String) -> String {
		"https://link.aiarcheology.com/f#v=1&i=\(id)&t=\(title)&u=https%3A%2F%2Fags.cuzk.cz%2Fav%2F"
	}

	private func control(_ id: String) -> XCUIElement {
		app.descendants(matching: .any).matching(identifier: id).firstMatch
	}

	private func openFindings(file: StaticString = #filePath, line: UInt = #line) {
		openDrawer(file: file, line: line)
		let findings = app.buttons[AID.drawerFindings]
		let dismiss = app.buttons[AID.findingsDismiss]
		for _ in 0..<2 {
			if findings.waitForExistence(timeout: 8), findings.isHittable { findings.tap() }
			if dismiss.waitForExistence(timeout: 8) { return }
		}
		XCTAssertTrue(dismiss.exists, "Findings sheet did not appear", file: file, line: line)
	}

	private func selectTab(_ name: String) {
		let picker = control(AID.findingsTab)
		XCTAssertTrue(picker.waitForExistence(timeout: 8), "the My/Received picker is missing")
		picker.buttons[name].tap()
	}

	// MARK: - The link reaches the store

	/// The whole feature in one pass: a tapped link is saved without being asked, and is findable
	/// afterwards under Received rather than among the user's own work.
	func testATappedLink_isStoredAndListedUnderReceived() {
		var config = LaunchConfig()
		config.sharedLinkURL = link(id: UUID().uuidString, title: "Rampart%20from%20a%20stranger")
		launch(config)

		let done = control(AID.sharedFindingDone)
		if done.waitForExistence(timeout: 15) == false {
			XCTFail("card never appeared. UI TREE:\n" + app.debugDescription)
			return
		}
		done.tap()

		openFindings()
		selectTab("Received")
		XCTAssertTrue(
			app.staticTexts["Rampart from a stranger"].waitForExistence(timeout: 8),
			"the received finding is not in the Received tab"
		)

		selectTab("My")
		XCTAssertFalse(
			app.staticTexts["Rampart from a stranger"].exists,
			"a received finding must not appear among the user's own findings"
		)
	}

	/// The id is a signature: the same link twice is one finding, not two.
	func testTheSameLinkTwice_storesOneFinding() {
		let identifier = UUID().uuidString
		var config = LaunchConfig()
		config.sharedLinkURL = link(id: identifier, title: "Only%20once")
		// Twice in ONE launch, which is the only way this can be tested at all (AIA-0836). The
		// previous shape relaunched with the same link and called that "tapping it again" — but every
		// UI-test launch is a fresh install, so the second delivery landed in an empty store and the
		// assertion below passed without a duplicate ever being possible. It is also the real case:
		// re-scanning a printed card while the app is open.
		config.sharedLinkDeliveries = 2
		launch(config)

		let done = control(AID.sharedFindingDone)
		XCTAssertTrue(done.waitForExistence(timeout: 15))
		done.tap()

		openFindings()
		selectTab("Received")
		XCTAssertEqual(
			app.staticTexts.matching(identifier: "Only once").count, 1,
			"opening one link twice must not store it twice"
		)
	}

	// MARK: - Read-only where the user actually taps

	/// Read-only was fiction until it held on the row you tap, not just in the flag.
	func testAReceivedFinding_cannotBeEditedFromTheList() {
		var config = LaunchConfig()
		config.sharedLinkURL = link(id: UUID().uuidString, title: "Not%20mine%20to%20edit")
		launch(config)

		let done = control(AID.sharedFindingDone)
		XCTAssertTrue(done.waitForExistence(timeout: 15))
		done.tap()

		openFindings()
		selectTab("Received")
		app.staticTexts["Not mine to edit"].tap()

		let title = control(AID.findingDetailTitle)
		XCTAssertTrue(title.waitForExistence(timeout: 8), "the received finding did not open")
		XCTAssertFalse(title.isEnabled, "a received finding's title must not be editable")

		XCTAssertFalse(
			control(AID.findingDetailSave).exists,
			"a read-only finding must not offer Save"
		)
		// Share deliberately stays: forwarding is not editing, and the sender keeps the credit.
		XCTAssertTrue(
			control(AID.findingDetailShare).exists,
			"Share must remain available on a received finding"
		)
	}

	// MARK: - The card itself

	/// Done is the only way out of the card, so it has to be on screen. It was previously clipped
	/// off the top by a fixed 560pt height on a short screen.
	func testTheSharedLinkCard_showsItsWayOutInLandscape() {
		var config = LaunchConfig()
		config.sharedLinkURL = link(id: UUID().uuidString, title: "Landscape")
		launch(config)

		XCUIDevice.shared.orientation = .landscapeLeft
		// Rotating back is a REQUEST, not a state change, so it is waited on: the next test in this
		// class launches into whatever orientation this one left behind, and relaunching the app does
		// not reset it (raised in review).
		defer {
			XCUIDevice.shared.orientation = .portrait
			_ = waitForPortrait()
		}

		// The shared helper, not a local copy. This test used to hand-roll the same wait as
		// `NSPredicate(format: "frame.size.width > frame.size.height")`, which reads `frame` through
		// KVC — that boxes the CGRect in an NSValue, which answers neither `size` nor `width`, so the
		// key path never resolved and the wait could not be fulfilled in ANY orientation (AIA-0849).
		XCTAssertTrue(waitForLandscape(), "the window never reported landscape")

		let done = control(AID.sharedFindingDone)
		XCTAssertTrue(done.waitForExistence(timeout: 15), "the card never appeared in landscape")

		// The window having rotated is not the card having re-laid out, and Done exists in portrait
		// too — so asserting `isHittable` the moment the window turns can be answered about the
		// pre-rotation layout and pass while the clipping is still to come (raised in review).
		//
		// So the check samples the window and the button TOGETHER, demands Done sit fully inside the
		// window vertically — which is what "clipped off the top" actually means — and requires that
		// to hold twice in a row, so no single mid-rotation snapshot can satisfy it.
		//
		// ## What this has NOT been shown to catch
		// Two negative controls were run against it and neither failed, so the strength of the
		// assertion below is unproven (AIA-0849, and honestly stated rather than assumed):
		//
		// - restoring the original `.frame(height: 560)` did not clip Done, because Done now lives
		//   in the toolbar *outside* the capped content — which is how the original bug was fixed,
		//   so that mutation can no longer reproduce it;
		// - `.offset(y: -400)` on the toolbar button did not move it, because SwiftUI places toolbar
		//   items itself.
		//
		// The wait itself IS verified: forced to stay portrait this test fails, rotated it passes.
		// What remains unverified is whether these assertions would notice a real clipping, and a
		// negative control that reproduces one is worth building before trusting them.
		var consecutiveGoodSamples = 0
		var lastObservation = "never sampled"
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline && consecutiveGoodSamples < 2 {
			// Every value in one sample is read ONCE, up front. Querying `isHittable` again while
			// building the diagnostic would ask the app a second time, and during a rotation the two
			// answers can come from different snapshots — so the failure message would describe a
			// state other than the one that actually failed (raised in review).
			let window = app.windows.firstMatch.frame
			let button = done.frame
			let isHittable = done.isHittable
			let isLandscape = window.width > window.height
			let sitsInsideTheWindow = button.minY >= window.minY && button.maxY <= window.maxY
			if isLandscape && sitsInsideTheWindow && isHittable {
				consecutiveGoodSamples += 1
			} else {
				consecutiveGoodSamples = 0
				lastObservation = "window \(window), Done \(button), hittable \(isHittable)"
			}
			if consecutiveGoodSamples < 2 { Thread.sleep(forTimeInterval: 0.4) }
		}

		XCTAssertEqual(
			consecutiveGoodSamples,
			2,
			"Done is off-screen in landscape — the card has no exit (\(lastObservation))"
		)
	}
}
