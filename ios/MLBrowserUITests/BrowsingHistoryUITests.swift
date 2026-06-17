//
//  BrowsingHistoryUITests.swift
//  MLBrowserUITests
//
//  AIA-0305: browsing-history coverage. Operates on the six demo history pages seeded into the
//  disposable UI-test store: the list renders them, a single entry can be deleted, and
//  clear-all empties the list. Selecting an entry (which loads the page) needs network and is
//  deferred — see UI_TESTING_PLAN_AIA-0305.md.
//

import XCTest

final class BrowsingHistoryUITests: UITestCase {

    private func openHistory(file: StaticString = #filePath, line: UInt = #line) {
        openSettings(file: file, line: line)
        XCTAssertTrue(scrollTo(AID.settingsHistory), "History link missing", file: file, line: line)
        // The History push happens inside the just-presented Settings sheet; on slow/cold (CI) sims
        // the first NavigationLink tap can be dropped while the sheet's NavigationStack is still
        // settling, leaving the screen un-pushed. Retry until the History anchor appears (the link
        // is gone once the push lands, so a stale re-tap can't happen).
        let clearButton = app.buttons[AID.historyClear]
        for _ in 0..<3 where clearButton.exists == false {
            let link = element(AID.settingsHistory)
            guard link.exists else { break }
            link.tap()
            _ = clearButton.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(
            clearButton.waitForExistence(timeout: 4),
            "History screen not shown", file: file, line: line
        )
    }

    /// The seeded history rows, each tagged on its URL label (a leaf element).
    private func historyRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: AID.historyItem)
    }

    func testHistory_showsSeededEntries() {
        launch()
        openHistory()
        XCTAssertTrue(historyRows().firstMatch.waitForExistence(timeout: 10), "No seeded history entries shown")
        // Assert multiple rows populate, not just one. Exact count is deliberately not asserted:
        // a SwiftUI List realizes only on-screen rows, so the query reflects visible rows, not the
        // six seeded entries.
        XCTAssertGreaterThanOrEqual(historyRows().count, 2, "Expected multiple seeded history entries")
    }

    // Deferred — XCUITest harness limitation, not an app bug. The per-row delete's data path is
    // fully covered at the unit level by `BrowsingHistoryRefreshTests`
    // (`testDeleteEntry_dropsOneRowFromFetchedResultsController` +
    // `testDeleteEntry_onRowsFetchedFreshFromStore_dropsRow`): the delete persists on the
    // viewContext and the backing NSFetchedResultsController drops the row. The UI e2e cannot be
    // automated: the trailing swipe actions DO reveal (verified by screenshot), but tapping the
    // *middle* destructive trash button never invokes its action under XCUITest — proven by
    // reopening the screen and seeing the store unchanged (row count 6→6→6). A full swipe only
    // auto-triggers the trailing-edge action, which here is copy, not delete. Re-enable if/when a
    // reliable swipe-action trigger exists (tracked with the swipe-to-delete testability work in
    // AIA-0308).
    func testHistory_deleteEntry_removesIt() throws {
        throw XCTSkip("XCUITest cannot fire the middle destructive swipe action; per-row delete + FRC refresh is covered by BrowsingHistoryRefreshTests. See AIA-0308.")
    }

    // AIA-0307: clear-all empties the list in place. The clear path runs a batch delete and
    // merges it into the viewContext, so the @FetchRequest must drop every row without reopening
    // the screen.
    func testHistory_clearAll_emptiesList() {
        launch()
        openHistory()
        let rows = historyRows()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "No seeded history entries shown")

        app.buttons[AID.historyClear].tap()
        // Locale is pinned to en, so the destructive confirm button is labelled "Clear". Scope the
        // query to the alert so it resolves the confirm button, not the section's own Clear button.
        let confirm = app.alerts.buttons["Clear"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Clear-all confirmation alert did not appear")
        confirm.tap()

        let emptied = NSPredicate(format: "count == 0")
        let expectation = XCTNSPredicateExpectation(predicate: emptied, object: rows)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
            "History list did not empty after clear-all — the @FetchRequest did not refresh"
        )
    }
}
