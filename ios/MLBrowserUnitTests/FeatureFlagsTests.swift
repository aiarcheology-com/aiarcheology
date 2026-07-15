//
//  FeatureFlagsTests.swift
//  AI ArcheologyTests
//
//  Remote feature flags (AIA-0350).
//

import XCTest
@testable import ML_Browser

final class FeatureFlagsTests: XCTestCase {

	/// The compiled defaults must preserve today's shipped behaviour exactly: both
	/// features on. This is the offline / first-launch / outage path — the flags
	/// deliberately fail *open* (see the spec's "Honest limits of the kill switch").
	func test_defaults_matchShippedBehaviour() {
		XCTAssertTrue(FeatureFlagKey.isModelCatalogEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagKey.isPaymentsEnabled.defaultValue)
	}

	/// The ConfigCat key is the rawValue — a declared literal, never a reflected symbol
	/// name, so release-build symbol stripping cannot silently break lookup. These
	/// strings must match the keys published in ConfigCat exactly.
	func test_rawValues_areTheConfigCatKeys() {
		XCTAssertEqual(FeatureFlagKey.isModelCatalogEnabled.rawValue, "isModelCatalogEnabled")
		XCTAssertEqual(FeatureFlagKey.isPaymentsEnabled.rawValue, "isPaymentsEnabled")
	}

	func test_defaultsSnapshot_usesEveryKeysDefault() {
		let sut = FeatureFlagSnapshot.defaults
		for key in FeatureFlagKey.allCases {
			XCTAssertEqual(sut[key], key.defaultValue, "\(key.rawValue) should use its default")
		}
	}

	/// A snapshot built from partial remote data falls back per-key — the path taken when
	/// ConfigCat is reachable but a flag has not been created yet.
	func test_snapshot_missingKeyFallsBackToDefault() {
		let sut = FeatureFlagSnapshot(values: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.isPaymentsEnabled)
		XCTAssertEqual(sut.isModelCatalogEnabled, FeatureFlagKey.isModelCatalogEnabled.defaultValue)
	}

	func test_snapshot_remoteValuesWin() {
		let sut = FeatureFlagSnapshot(values: [.isModelCatalogEnabled: false, .isPaymentsEnabled: false])
		XCTAssertFalse(sut.isModelCatalogEnabled)
		XCTAssertFalse(sut.isPaymentsEnabled)
	}
}

final class StaticFeatureFlagProviderTests: XCTestCase {

	func test_withoutOverrides_returnsDefaults() {
		let sut = StaticFeatureFlagProvider()
		XCTAssertEqual(sut.currentSnapshot(), FeatureFlagSnapshot.defaults)
	}

	func test_overrides_win() {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
		XCTAssertTrue(sut.currentSnapshot().isModelCatalogEnabled)
	}

	/// `refresh()` must be a no-op that never touches the network in tests.
	func test_refresh_doesNotChangeValues() async {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		await sut.refresh()
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
	}
}
