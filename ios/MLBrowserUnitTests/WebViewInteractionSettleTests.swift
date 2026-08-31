//
//  WebViewInteractionSettleTests.swift
//  AI ArcheologyTests
//
//  Tests for domInteractionEndSettlesContent(isDragging:isDecelerating:) — the decision
//  that stops a flick's `touchend` from telling detection the page has stopped moving
//  while it is still decelerating (AIA-0808).
//

import XCTest
import WebKit
@testable import ML_Browser

@MainActor
final class WebViewInteractionSettleTests: XCTestCase {

    private typealias Coordinator = MLWebView.Coordinator

    // MARK: - Still moving -> the DOM's `end` must not publish idle

    /// The regression this exists for. The injected script fires `end` 150 ms after `touchend`,
    /// which on a flick lands inside deceleration. Publishing idle there hands detection a moving
    /// frame, and the boxes are drawn where the objects no longer are.
    func testDecelerating_DoesNotSettle() {
        XCTAssertFalse(
            Coordinator.domInteractionEndSettlesContent(isDragging: false, isDecelerating: true)
        )
    }

    /// A second finger down, or a `touchend` from one of several touches: the drag continues.
    func testDragging_DoesNotSettle() {
        XCTAssertFalse(
            Coordinator.domInteractionEndSettlesContent(isDragging: true, isDecelerating: false)
        )
    }

    func testDraggingAndDecelerating_DoesNotSettle() {
        XCTAssertFalse(
            Coordinator.domInteractionEndSettlesContent(isDragging: true, isDecelerating: true)
        )
    }

    // MARK: - Genuinely still -> settle

    /// A tap, or a drag released without throwing the page. Nothing else will report the settle in
    /// this case — `scrollViewDidEndDecelerating` never fires when there was no deceleration — so
    /// suppressing here would strand the overlay until the next timer tick.
    func testStill_Settles() {
        XCTAssertTrue(
            Coordinator.domInteractionEndSettlesContent(isDragging: false, isDecelerating: false)
        )
    }

    // MARK: - The decision is motion-only

    /// Guards the shape of the rule rather than one case of it: settling must depend on the two
    /// motion inputs and nothing else, so every combination is pinned and a later edit that adds a
    /// hidden condition fails here.
    func testEveryCombinationIsPinned() {
        let expected: [(dragging: Bool, decelerating: Bool, settles: Bool)] = [
            (false, false, true),
            (false, true, false),
            (true, false, false),
            (true, true, false),
        ]
        for row in expected {
            XCTAssertEqual(
                Coordinator.domInteractionEndSettlesContent(
                    isDragging: row.dragging,
                    isDecelerating: row.decelerating
                ),
                row.settles,
                "dragging=\(row.dragging) decelerating=\(row.decelerating)"
            )
        }
    }
}
