//
//  FeatureSessionTests.swift
//  MLBrowserUnitTests
//
//  AIA-0390: proves AC2 — each feature session builds/exercises its state in ISOLATION, with only
//  its own minimal deps, no AppState and no full composition graph. Each test FORCES the session's
//  owned lazy internal (not just constructs the shell) so it's a real proof the feature builds.
//

import XCTest
@testable import ML_Browser

@MainActor
final class FeatureSessionTests: XCTestCase {

	/// The detection feature builds without AppState: guide is constructed from the injected
	/// singletons and the `unowned` snapAdjustment edge points at this session's owned instance.
	func testDetectionSession_buildsGuideInIsolation() {
		let dataController = DataController(inMemory: true)
		let settings = Settings()
		let snap = SnapState(settings: settings)
		let session = DetectionSession(
			snap: snap,
			deep: DeepState(dataController: dataController),
			settings: settings,
			dataController: dataController,
			demoDataManager: DemoDataManager(dataController: dataController)
		)

		// Forces `guide` (and its `snapAdjustment`) — the actual isolation proof.
		XCTAssertTrue(session.guide.snap === snap, "guide is wired to the injected snap instance")
		XCTAssertTrue(session.guide.snapAdjustment === session.snapAdjustment,
					  "guide borrows this session's owned snapAdjustment (unowned-edge invariant)")
		XCTAssertEqual(session.guide.mode, .web, "default guide mode preserved")
	}

	/// The browser feature builds without AppState: browserState + the visit-trail recorder that
	/// depends on it both construct from the injected settings/dataController alone.
	func testBrowserSession_buildsBrowserStateInIsolation() {
		let dataController = DataController(inMemory: true)
		let session = BrowserSession(settings: Settings(), dataController: dataController)

		let browserState = session.browserState
		XCTAssertTrue(session.browserState === browserState, "browserState is a stable lazy singleton")
		// Forcing the trail (which is built against browserState) must not crash in isolation.
		let trail = session.visitTrail
		XCTAssertTrue(session.visitTrail === trail, "visitTrail is a stable lazy singleton")
	}

	/// The account feature builds without AppState: authState + subscriptionState wrap the injected
	/// (mock) providers with no wider graph.
	func testAccountSession_buildsAuthAndSubscriptionInIsolation() {
		let session = AccountSession(
			authProvider: MockAuthProvider.fromLaunchArguments(),
			subscriptionProvider: MockSubscriptionProvider.fromLaunchArguments()
		)

		let authState = session.authState
		XCTAssertTrue(session.authState === authState, "authState is a stable lazy singleton")
		let subscriptionState = session.subscriptionState
		XCTAssertTrue(session.subscriptionState === subscriptionState, "subscriptionState is a stable lazy singleton")
	}
}
