//
//  AppRuntimeTests.swift
//  MLBrowserUnitTests
//
//  AIA-0970.
//

import Combine
import XCTest
@testable import ML_Browser

/// The launch-order mechanism `AppRuntime` starts auth through: `afterReady` never runs its operation
/// before `AppState.isReady`.
///
/// `AccountAnalyticsCoordinator` depends on entitlement resolving before auth at launch; starting
/// auth first would mark every signed-in subscriber anonymous on every launch. This pins the helper,
/// not its call site: an `AppState` cannot be built outside the composition root, so that
/// `startAuthWhenReady` goes through `afterReady` is left to review.
@MainActor
final class AppRuntimeTests: XCTestCase {

	private final class Readiness: ObservableObject {
		@Published var isReady = false
	}

	@MainActor
	private final class Probe {
		var runs = 0
	}

	func test_afterReady_doesNotRunBeforeReady_thenRunsOnce() async {
		let readiness = Readiness()
		let probe = Probe()
		let task = AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }

		// Give the task every chance to run early.
		for _ in 0..<20 {
			await Task.yield()
		}
		XCTAssertEqual(probe.runs, 0, "auth must not start before the app is ready")

		readiness.isReady = true
		await task.value
		XCTAssertEqual(probe.runs, 1)
	}

	func test_afterReady_runsAtOnceWhenAlreadyReady() async {
		let readiness = Readiness()
		readiness.isReady = true
		let probe = Probe()
		await AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }.value
		XCTAssertEqual(probe.runs, 1)
	}

	func test_afterReady_cancelledBeforeReady_neverRuns() async {
		let readiness = Readiness()
		let probe = Probe()
		let task = AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }
		task.cancel()
		readiness.isReady = true
		await task.value
		XCTAssertEqual(probe.runs, 0)
	}
}
