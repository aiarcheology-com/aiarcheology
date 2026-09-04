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
		defer { XCUIDevice.shared.orientation = .portrait }

		// Rotation is asynchronous, and the card exists in portrait too. Without waiting for the
		// window to actually be wider than it is tall, `isHittable` can be answered about a portrait
		// layout — passing while saying nothing about the landscape clipping this test exists for.
		let isLandscape = NSPredicate(format: "frame.size.width > frame.size.height")
		expectation(for: isLandscape, evaluatedWith: app.windows.firstMatch)
		waitForExpectations(timeout: 10)

		let done = control(AID.sharedFindingDone)
		XCTAssertTrue(done.waitForExistence(timeout: 15), "the card never appeared in landscape")
		XCTAssertTrue(done.isHittable, "Done is off-screen in landscape — the card has no exit")
	}
}
