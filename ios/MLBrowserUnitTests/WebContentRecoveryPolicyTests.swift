//
//  WebContentRecoveryPolicyTests.swift
//  AI ArcheologyTests
//
//  AIA-0509: the escalation ladder that bounds automatic web-view recovery, so a page that
//  reliably wedges WebKit cannot produce an infinite reload/rebuild loop.
//
//  The policy takes `now` as a parameter rather than reading a clock, so window expiry is
//  exercised with date arithmetic — this suite never waits on real time.
//

import XCTest
@testable import ML_Browser

final class WebContentRecoveryPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Ladder order

    func testNextRecovery_ClimbsReloadThenRebuildThenExhausts() {
        var sut = WebContentRecoveryPolicy()

        let first = sut.nextRecovery(now: now)
        let second = sut.nextRecovery(now: now)
        let third = sut.nextRecovery(now: now)

        XCTAssertEqual(first, .reloadFromOrigin, "Cheapest rung first")
        XCTAssertEqual(second, .rebuild)
        XCTAssertNil(third, "The ladder must exhaust and surface the failure, not loop")
    }

    func testNextRecovery_ConsumesTheRungItReturns() {
        var sut = WebContentRecoveryPolicy()

        let first = sut.nextRecovery(now: now)
        let second = sut.nextRecovery(now: now)

        // The whole point of the budget: a rung that already failed must not be retried
        // automatically inside the same window.
        XCTAssertNotEqual(first, second, "No rung may be handed out twice in one window")
    }

    // MARK: - Window

    func testNextRecovery_AfterTheWindowExpires_ReplenishesTheBudget() {
        var sut = WebContentRecoveryPolicy()
        _ = sut.nextRecovery(now: now)
        _ = sut.nextRecovery(now: now)
        XCTAssertNil(sut.nextRecovery(now: now), "Precondition: the ladder is exhausted")

        let afterWindow = now.addingTimeInterval(WebContentRecoveryPolicy.defaultWindow + 1)

        XCTAssertEqual(sut.nextRecovery(now: afterWindow), .reloadFromOrigin)
    }

    func testUserDidNavigate_ResetsTheBudget() {
        var sut = WebContentRecoveryPolicy()
        _ = sut.nextRecovery(now: now)
        _ = sut.nextRecovery(now: now)

        // Automatic recovery is bounded; deliberate navigation is not.
        sut.userDidNavigate()

        XCTAssertEqual(sut.nextRecovery(now: now), .reloadFromOrigin)
    }

    // MARK: - Manual retry

    func testManualRetry_OnAFreshPolicy_ReloadsFromOrigin() {
        var sut = WebContentRecoveryPolicy()

        XCTAssertEqual(sut.manualRetry(now: now), .reloadFromOrigin)
    }

    func testManualRetry_AfterTheLadderIsExhausted_RebuildsOnTheFirstTap() {
        var sut = WebContentRecoveryPolicy()
        _ = sut.nextRecovery(now: now)
        _ = sut.nextRecovery(now: now)

        // Not `.reloadFromOrigin`: a user tapping Try Again on a page whose reload has already
        // failed must not need two taps to reach the rung that might actually work.
        XCTAssertEqual(sut.manualRetry(now: now), .rebuild)
    }

    func testManualRetry_AfterOnlyTheReloadRungWasSpent_Rebuilds() {
        var sut = WebContentRecoveryPolicy()
        XCTAssertEqual(sut.nextRecovery(now: now), .reloadFromOrigin)

        // The boundary between "fresh" and "exhausted": one rung spent. Try Again performs the
        // NEXT rung, so replaying the reload that just failed would waste the user's tap.
        XCTAssertEqual(sut.manualRetry(now: now), .rebuild)
    }

    func testManualRetry_ReplenishesTheBudgetItSpends() {
        var sut = WebContentRecoveryPolicy()
        _ = sut.nextRecovery(now: now)
        _ = sut.nextRecovery(now: now)

        _ = sut.manualRetry(now: now)

        // User intent is never rate-limited: the rung it did not spend is available again.
        XCTAssertEqual(sut.nextRecovery(now: now), .reloadFromOrigin)
    }

    // MARK: - Session restore (one strike)

    func testConsumeSessionRestore_GrantsExactlyOneRestore() {
        var sut = WebContentRecoveryPolicy()

        XCTAssertTrue(sut.consumeSessionRestore(), "A first rebuild may carry the session forward")
        // One strike: re-entering the ladder makes the restored session itself a suspect, so
        // the next rebuild drops it and does a bare cache-busting load instead.
        XCTAssertFalse(sut.consumeSessionRestore())
    }

    /// Regression guard. The restore was originally derived from "has the rebuild rung been
    /// spent", which is always true by the time the caller can ask — `nextRecovery` marks the
    /// rung spent before it returns — so the session was never restored and Back/Forward was
    /// always lost. The two must stay independently tracked.
    func testConsumeSessionRestore_SurvivesTheRebuildRungBeingSpent() {
        var sut = WebContentRecoveryPolicy()

        XCTAssertEqual(sut.nextRecovery(now: now), .reloadFromOrigin)
        XCTAssertEqual(sut.nextRecovery(now: now), .rebuild)

        XCTAssertTrue(sut.consumeSessionRestore(), "Spending the rebuild rung must not cost the restore")
    }

    func testConsumeSessionRestore_IsReplenishedByUserIntent() {
        var sut = WebContentRecoveryPolicy()
        XCTAssertTrue(sut.consumeSessionRestore())

        sut.userDidNavigate()

        XCTAssertTrue(sut.consumeSessionRestore())
    }
}
