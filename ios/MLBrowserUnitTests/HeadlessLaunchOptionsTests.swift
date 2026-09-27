//
//  HeadlessLaunchOptionsTests.swift
//  MLBrowserUnitTests
//
//  AIA-0970.
//

import Combine
import HeadlessKit
import XCTest
@testable import ML_Browser

/// The headless build's launch arguments. Compiled into every Debug build so this suite can run in
/// the ordinary unit-test host; only the headless build ever reads them at launch.
final class HeadlessLaunchOptionsTests: XCTestCase {

	func test_readsTheSubscriptionMockAndRepeatedFlagPins_ignoringOtherArguments() {
		let options = HeadlessLaunchOptions(arguments: [
			"/path/ML Browser",
			"-AppleLanguages", "(en)",
			"-mockSubscription", "subscribed",
			"-headlessFlag", "isPaymentsEnabled=true",
			"-headlessFlag", "isFreeAccessPeriodEnabled=false"
		])
		XCTAssertEqual(options.mockSubscription, "subscribed")
		XCTAssertEqual(options.flagOverrides, [.isPaymentsEnabled: true, .isFreeAccessPeriodEnabled: false])
		XCTAssertEqual(options.json, [
			"mockSubscription": "subscribed",
			"flags": ["isPaymentsEnabled": true, "isFreeAccessPeriodEnabled": false],
			"stagedImages": []
		])
	}

	func test_readsRepeatedStagedImages_inLaunchOrder_andEchoesThem() {
		let options = HeadlessLaunchOptions(arguments: [
			"/path/ML Browser",
			"-headlessStagedImage", "terrain-b.png",
			"-mockSubscription", "subscribed",
			"-headlessStagedImage", "terrain-a.png"
		])
		XCTAssertEqual(options.stagedImages, ["terrain-b.png", "terrain-a.png"])
		XCTAssertEqual(options.json, [
			"mockSubscription": "subscribed",
			"flags": [:],
			"stagedImages": ["terrain-b.png", "terrain-a.png"]
		])
	}

	func test_aStagedImageName_isABareFileName() {
		XCTAssertTrue(HeadlessLaunchOptions.isStagedImageName("terrain.png"))
		XCTAssertTrue(HeadlessLaunchOptions.isStagedImageName("a..b.png"), "dots inside a name are not a path")
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName(""))
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName("."))
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName(".."))
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName("../endpoint.json"))
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName("sub/terrain.png"))
		XCTAssertFalse(HeadlessLaunchOptions.isStagedImageName("-mockSubscription"), "a missing value must not swallow the next option")
	}

	func test_withoutOptions_theLaunchIsTheRealComposition() {
		let options = HeadlessLaunchOptions(arguments: ["/path/ML Browser"])
		XCTAssertNil(options.mockSubscription)
		XCTAssertTrue(options.flagOverrides.isEmpty)
		XCTAssertTrue(options.stagedImages.isEmpty)
		XCTAssertEqual(options.json, ["flags": [:], "stagedImages": []])
	}
}

/// Pins must hold on the change stream too, not just the first snapshot: `FlagLaunchValueMirror`
/// records what `FeatureFlagsState` publishes, and launch-captured flags resolve through it on the
/// next launch.
@MainActor
final class OverridingFeatureFlagProviderTests: XCTestCase {

	func test_pinsWin_andEveryOtherValueIsLive() {
		let live = LiveFlagProvider(initial: FeatureFlagSnapshot(
			values: [.isPaymentsEnabled: false, .isModelCatalogEnabled: false],
			appMessagesJSON: "[]"
		))
		let provider = OverridingFeatureFlagProvider(base: live, overrides: [.isPaymentsEnabled: true])
		let snapshot = provider.currentSnapshot()
		XCTAssertTrue(snapshot.isPaymentsEnabled)
		XCTAssertFalse(snapshot.isModelCatalogEnabled)
		XCTAssertEqual(snapshot.appMessagesJSON, "[]")
	}

	func test_aLiveChange_republishes_withThePinsStillApplied() async {
		let live = LiveFlagProvider(initial: FeatureFlagSnapshot(values: [.isPaymentsEnabled: false]))
		let sut = FeatureFlagsState(provider: OverridingFeatureFlagProvider(base: live, overrides: [.isPaymentsEnabled: true]))
		XCTAssertTrue(sut.snapshot.isPaymentsEnabled, "precondition: pinned from the first snapshot")
		XCTAssertTrue(sut.snapshot.isModelCatalogEnabled, "precondition: the live default")

		let republished = expectation(description: "the live change is republished")
		let cancellable = sut.$snapshot
			.dropFirst()
			.sink { if $0.isModelCatalogEnabled == false { republished.fulfill() } }
		live.emit(FeatureFlagSnapshot(values: [.isPaymentsEnabled: false, .isModelCatalogEnabled: false]))

		await fulfillment(of: [republished], timeout: 2)
		cancellable.cancel()
		XCTAssertFalse(sut.snapshot.isModelCatalogEnabled, "the live change arrives")
		XCTAssertTrue(sut.snapshot.isPaymentsEnabled, "the pin survives it")
	}
}

/// Stands in for ConfigCat: values that change after construction, then a signal.
private final class LiveFlagProvider: FeatureFlagProviding, @unchecked Sendable {
	// @unchecked: `snapshot` is only accessed under `lock`.
	private let lock = NSLock()
	private var snapshot: FeatureFlagSnapshot
	private let stream: AsyncStream<Void>
	private let continuation: AsyncStream<Void>.Continuation

	init(initial: FeatureFlagSnapshot) {
		snapshot = initial
		(stream, continuation) = AsyncStream<Void>.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		lock.withLock { snapshot }
	}

	func refresh() async {}

	func changes() -> AsyncStream<Void> { stream }

	func setUser(id: String, custom: [String: String]) {}
	func clearUser() {}

	func emit(_ next: FeatureFlagSnapshot) {
		lock.withLock { snapshot = next }
		continuation.yield()
	}
}
