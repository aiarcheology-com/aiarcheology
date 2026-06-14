//
//  AddressBarUITests.swift
//  MLBrowserUITests
//
//  AIA-0305: address-bar / location-sheet coverage. Tapping the address bar opens the location
//  sheet, which lists the seeded history and exposes the full-URLs toggle; the sheet dismisses.
//  Actually opening a chosen page needs network and is deferred — see UI_TESTING_PLAN_AIA-0305.md.
//

import XCTest

final class AddressBarUITests: UITestCase {

    private func openLocationSheet(file: StaticString = #filePath, line: UInt = #line) {
        let addressBar = app.buttons[AID.address]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 10), "Address bar missing", file: file, line: line)
        addressBar.tap()
        XCTAssertTrue(
            element(AID.locationInput).waitForExistence(timeout: 10),
            "Location sheet did not open", file: file, line: line
        )
    }

    func testAddressBar_opensAndDismissesLocationSheet() {
        launch()
        openLocationSheet()
        app.buttons[AID.locationDismiss].tap()
        XCTAssertTrue(
            waitForDisappearance(of: element(AID.locationInput)),
            "Location sheet did not dismiss"
        )
    }

    func testLocationSheet_showsSeededHistory() {
        launch()
        openLocationSheet()
        let firstItem = app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10), "Seeded history not shown in location sheet")
    }

    func testLocationSheet_toggleFullUrls_keepsHistoryVisible() {
        launch()
        openLocationSheet()
        let firstItem = app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10))

        let fullUrls = app.buttons[AID.locationFullUrls]
        XCTAssertTrue(fullUrls.waitForExistence(timeout: 5), "Full-URLs toggle missing")
        fullUrls.tap()

        // History remains listed after toggling the display mode.
        XCTAssertTrue(app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch.waitForExistence(timeout: 5))
    }
}
