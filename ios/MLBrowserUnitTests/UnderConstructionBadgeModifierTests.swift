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
/// introspectable), but the gating decision — `AppEnvironment.purchasesUseSandbox`, the default
/// for `underConstructionBadge()` — is, and that's the part that must not regress.
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
		// report `.appStore` (the bug `purchasesUseSandbox` exists to paper over).
		XCTAssertTrue(AppEnvironment.purchasesUseSandbox)
	}

	func test_modifier_constructsForBothStates() {
		// Both states are valid; `false` is a pure pass-through (App Store production).
		XCTAssertFalse(UnderConstructionBadgeModifier(isActive: false).isActive)
		XCTAssertTrue(UnderConstructionBadgeModifier(isActive: true).isActive)
	}
}
