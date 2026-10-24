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

    /// AIA-0338: the address bar's clear (✕) opens the composer already blank, so the user can type
    /// a fresh URL without first clearing the prefilled current one. The clear button is iPhone-only
    /// (both the portrait-bottom and landscape-top placements; iPad/Mac are unchanged); this test
    /// exercises the portrait/bottom placement. A local fixture is loaded so the bar has a URL (the
    /// clear button is hidden on a blank page).
    func testAddressBarClear_opensComposerCleared() {
        launch(LaunchConfig(pageScenario: .localFixture, fixtureName: "uitest_page"))
        guard isPhoneIdiom else { return }
        XCTAssertTrue(
            waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
            "Fixture did not become the live page, so the address bar has no URL to clear"
        )

        let clear = app.buttons[AID.addressClear]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Bottom address-bar clear button missing")
        clear.tap()

        let input = app.textFields[AID.locationInput]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Composer did not open")
        // A cleared field shows only its placeholder; assert against placeholderValue (the
        // documented source) rather than `value`, which varies across XCTest releases.
        XCTAssertEqual(input.placeholderValue, Self.locationPlaceholder, "Composer should open with a cleared field")
    }

    /// Mirrors `L10n.Browser.Location.placeholder` (the app target isn't linked here).
    private static let locationPlaceholder = "Search or enter website name"

    func testLocationSheet_showsSeededHistory() {
        launch()
        openLocationSheet()
        let items = app.buttons.matching(identifier: AID.locationHistoryItem)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "Seeded history not shown in location sheet")
        // Multiple items, not just one. Exact count not asserted (lazy List realization).
        XCTAssertGreaterThanOrEqual(items.count, 2, "Expected multiple seeded history items")
    }

    /// Behavioral coverage for the debounced filter; debounce timing is not asserted by UI polling.
    func testLocationSheet_filterClearAndReopenRestoresHistory() {
        launch()
        openLocationSheet()
        let firstItem = app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10))

        let input = app.textFields[AID.locationInput]
        let query = "no-matching-history.invalid"
        input.tap()
        input.typeText(query)
        XCTAssertTrue(waitForDisappearance(of: firstItem), "Unmatched query should hide history")

        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10), "Clearing the query should restore history")

        input.typeText(query)
        XCTAssertTrue(waitForDisappearance(of: firstItem), "Second query should become the active filter")
        app.buttons[AID.locationDismiss].tap()
        XCTAssertTrue(waitForDisappearance(of: input))
        openLocationSheet()
        XCTAssertNotEqual(input.value as? String, query, "Reopening should discard the previous query")
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10), "Reopening should reset the previous filter")
    }

    func testLocationSheet_prefilledAddressDoesNotFilterHistory() {
        launch(LaunchConfig(pageScenario: .localFixture, fixtureName: "uitest_page"))
        XCTAssertTrue(waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"))
        openLocationSheet()

        let input = app.textFields[AID.locationInput]
        let originalAddress = input.value as? String ?? ""
        XCTAssertTrue(originalAddress.contains("uitest_page.html"), "Current page should be prefilled")
        let items = app.buttons.matching(identifier: AID.locationHistoryItem)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))

        // The current address is selected on initial focus, so typing replaces the prefill.
        let query = "no-matching-history.invalid"
        input.typeText(query)
        XCTAssertEqual(input.value as? String, query)
        XCTAssertTrue(waitForDisappearance(of: items.firstMatch))
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        input.typeText(originalAddress)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "Restoring the prefill should restore history")
        XCTAssertGreaterThanOrEqual(items.count, 2, "Prefilling must not narrow history to the current page")
    }

    // Smoke check: the full-URLs control is present and interactive, and toggling the display
    // mode keeps the location sheet functional (history still listed). The per-row host↔full-URL
    // truncation change itself is not asserted: each row button carries its testability identifier
    // as its accessibility label, so the underlying URL text isn't reliably observable here.
    // Verifying the visual truncation belongs to a snapshot test, not an XCUITest assertion.
    func testLocationSheet_toggleFullUrls_keepsSheetFunctional() {
        launch()
        openLocationSheet()
        let firstItem = app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch
        XCTAssertTrue(firstItem.waitForExistence(timeout: 10))

        let fullUrls = app.buttons[AID.locationFullUrls]
        XCTAssertTrue(fullUrls.waitForExistence(timeout: 5), "Full-URLs toggle missing")
        XCTAssertTrue(fullUrls.isHittable, "Full-URLs toggle is not interactive")
        fullUrls.tap()

        // The sheet stays functional and history is still listed after toggling the display mode.
        XCTAssertTrue(
            app.buttons.matching(identifier: AID.locationHistoryItem).firstMatch.waitForExistence(timeout: 5),
            "History no longer listed after toggling display mode"
        )
    }
}
