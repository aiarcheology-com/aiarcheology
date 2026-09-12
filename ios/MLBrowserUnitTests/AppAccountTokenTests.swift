//
//  AppAccountTokenTests.swift
//  MLBrowserUnitTests
//
//  AIA-0518: the account tag StoreKit attaches to a purchase.
//
//  Previously unreachable: the derivation sat behind a read of `Clerk.shared`, which traps when
//  Clerk was never configured — the state of every test process. Any test that reached
//  `purchase(_:)` died with a signal trap before StoreKit was consulted at all.
//

import XCTest
@testable import ML_Browser

final class AppAccountTokenTests: XCTestCase {

	/// Shaped like a real Clerk id, which is not a UUID — the whole reason a fold exists.
	private let accountA = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
	private let accountB = "user_2bbbbbbbbbbbbbbbbbbbbbbbbb"

	/// Signed out means no tag, not a tag for nobody: StoreKit would happily accept a constant
	/// UUID and every anonymous purchase would reconcile to the same phantom account.
	func testMake_NoAccount_ProducesNoToken() {
		XCTAssertNil(AppAccountToken.make(from: nil))
	}

	func testMake_Account_ProducesAToken() {
		XCTAssertNotNil(AppAccountToken.make(from: accountA))
	}

	/// The property the whole mechanism exists for. `Hasher` is seeded per process run, so a
	/// `Hasher`-based fold would give the same user a different token on every launch and no
	/// backend could ever reconcile them — this is the regression guard against that swap.
	func testMake_SameAccount_IsStableAcrossCalls() {
		XCTAssertEqual(AppAccountToken.make(from: accountA), AppAccountToken.make(from: accountA))
	}

	/// Pinned to a literal, because same-process stability alone cannot catch a change of hash:
	/// a swapped algorithm stays self-consistent within a run and silently orphans every
	/// transaction already tagged with the old scheme.
	func testMake_Account_MatchesTheirPinnedSHA256Derivation() {
		XCTAssertEqual(
			AppAccountToken.make(from: "user_2aaaaaaaaaaaaaaaaaaaaaaaaa")?.uuidString,
			"DD135E7B-3747-608A-C4F7-B711B9E9DFB8"
		)
	}

	/// Distinct accounts must not collide, or two people's purchases reconcile to one.
	func testMake_DifferentAccounts_ProduceDifferentTokens() {
		XCTAssertNotEqual(AppAccountToken.make(from: accountA), AppAccountToken.make(from: accountB))
	}

	/// An empty identifier is still an identifier — it must map, not silently become "signed
	/// out". Only `nil` means no account.
	func testMake_EmptyIdentifier_StillProducesAToken() {
		XCTAssertNotNil(AppAccountToken.make(from: ""))
	}
}
