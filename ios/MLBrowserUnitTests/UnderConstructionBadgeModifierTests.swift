//
//  UnderConstructionBadgeModifierTests.swift
//  AI ArcheologyTests
//
//  Covers the gating contract of the under-construction badge (AIA-0354).
//

import XCTest
@testable import ML_Browser

/// The badge's whole purpose is to appear wherever in-app purchases aren't real money and to
/// vanish in real App Store production. The visual decoration is a SwiftUI overlay (not unit
/// introspectable), but the gating decision — `AppEnvironment.showsUnderConstructionBadge`, the
/// default for `underConstructionBadge()` — is, and that's the part that must not regress.
///
/// `@MainActor`: `UnderConstructionBadgeModifier` is a `ViewModifier`, so its `isActive` is
/// main-actor-isolated; reading it inside XCTest's nonisolated assertion autoclosures warns
/// otherwise (Swift 6 concurrency checking).
@MainActor
final class UnderConstructionBadgeModifierTests: XCTestCase {

	func test_defaultGate_isActiveUnderTests() {
		// Tests run on the simulator / a Debug build, where purchases are always sandboxed, so
		// the default gate must resolve "active" — exactly the badge's intended audience. This
		// must hold even though a local StoreKit-test receipt can make `distributionChannel`
		// report `.appStore` (the bug the simulator/Debug short-circuit exists to paper over).
		XCTAssertTrue(AppEnvironment.showsUnderConstructionBadge)
	}

	/// **The bug this ticket fixes** (AIA-0458): an unidentifiable channel must NOT be decorated.
	///
	/// `distributionChannel` recognises the App Store only by finding a receipt file on disk, and
	/// Apple documents that the app receipt can be absent until refreshed — after a restore from
	/// backup, for instance. Such an install reports `.unknown`. The badge used to be gated on
	/// `purchasesUseSandbox`, which decides by *elimination* (`!= .appStore`), so `.unknown`
	/// resolved to "sandbox" and put a yellow wrench on a paying customer's Subscribe button.
	///
	/// Asserted against the real function rather than a copy of its switch: this fails if the
	/// classification is reverted to elimination.
	func test_unidentifiableChannel_isNotDecorated() {
		XCTAssertFalse(AppEnvironment.decoratesControls(on: .unknown))
		XCTAssertFalse(AppEnvironment.decoratesControls(on: .appStore))
	}

	/// The other direction: the badge must still reach the testers it exists for. A gate that
	/// fails closed everywhere would pass the test above and be useless.
	func test_nonProductionChannels_areDecorated() {
		XCTAssertTrue(AppEnvironment.decoratesControls(on: .developmentLike))
		XCTAssertTrue(AppEnvironment.decoratesControls(on: .testFlightLike))
	}

	/// `purchasesUseSandbox` keeps its own meaning — for a caller asking "is this real money?",
	/// an unidentifiable channel must still answer "assume not". The two properties are supposed
	/// to disagree on `.unknown`; that disagreement is the fix, so it is pinned here.
	func test_theTwoGatesDisagreeOnUnknown_whichIsThePoint() {
		XCTAssertNotEqual(
			AppEnvironment.decoratesControls(on: .unknown),
			AppEnvironment.DistributionChannel.unknown != .appStore,
			"purchasesUseSandbox's elimination rule treats .unknown as sandbox; the badge must not."
		)
	}

	func test_modifier_constructsForBothStates() {
		// Both states are valid; `false` is a pure pass-through (App Store production).
		XCTAssertFalse(UnderConstructionBadgeModifier(isActive: false).isActive)
		XCTAssertTrue(UnderConstructionBadgeModifier(isActive: true).isActive)
	}
}
