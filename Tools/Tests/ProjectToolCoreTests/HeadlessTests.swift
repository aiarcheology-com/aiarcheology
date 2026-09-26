//
//  HeadlessTests.swift
//  ProjectToolCoreTests
//
//  AIA-0970.
//

import Foundation
import HeadlessKit
import XCTest
@testable import ProjectToolCore

final class HeadlessDeviceTests: XCTestCase {

	func testDeviceNamesCarryThePrefix() throws {
		XCTAssertEqual(try HeadlessDevice.deviceName(for: "a"), "aia-headless-a")
		XCTAssertEqual(try HeadlessDevice.deviceName(for: "user-b2"), "aia-headless-user-b2")
	}

	func testUnsafeInstallationNamesAreRefused() {
		for name in ["", "-a", "A", "a b", "a/b", "../x", String(repeating: "a", count: 41)] {
			XCTAssertThrowsError(try HeadlessDevice.deviceName(for: name), name)
		}
	}

	func testOnlyPrefixedDevicesAreTheTools() {
		XCTAssertTrue(HeadlessDevice.isToolDevice(named: "aia-headless-a"))
		XCTAssertFalse(HeadlessDevice.isToolDevice(named: "aia-headless-"))
		XCTAssertFalse(HeadlessDevice.isToolDevice(named: "iPhone 18 Pro"))
		XCTAssertFalse(HeadlessDevice.isToolDevice(named: "ship-ticket-runner"))
	}
}

final class HeadlessLaunchArgumentsTests: XCTestCase {

	func testOptionsBecomeLaunchArgumentsInAStableOrder() throws {
		let arguments = try HeadlessLaunchArguments.make(from: [
			"mockSubscription": "subscribed",
			"flags": ["isPaymentsEnabled": true, "isFreeAccessPeriodEnabled": false]
		])
		XCTAssertEqual(arguments, [
			"-mockSubscription", "subscribed",
			"-headlessFlag", "isFreeAccessPeriodEnabled=false",
			"-headlessFlag", "isPaymentsEnabled=true"
		])
		XCTAssertEqual(try HeadlessLaunchArguments.make(from: [:]), [])
	}

	func testMistakesAreErrors() {
		let invalid: [JSONValue] = [
			"subscribed",
			["mockSubscriptions": "subscribed"],
			["mockSubscription": "yes"],
			["flags": ["isPaymentsEnabled": "true"]],
			["flags": true]
		]
		for options in invalid {
			XCTAssertThrowsError(try HeadlessLaunchArguments.make(from: options), options.jsonString)
		}
	}
}

final class HeadlessCommandLineTests: XCTestCase {

	func testCommands() throws {
		XCTAssertEqual(try HeadlessCommandLine.parse(["state"]), .state)
		XCTAssertEqual(try HeadlessCommandLine.parse(["help"]), .help)
		XCTAssertEqual(try HeadlessCommandLine.parse(["goto", "drawer"]), .goto("drawer"))
		XCTAssertEqual(try HeadlessCommandLine.parse(["perform", "enable", "id=abc"]), .perform(action: "enable", arguments: ["id": "abc"]))
		XCTAssertEqual(
			try HeadlessCommandLine.parse(["wait", "model-loaded", "id=abc", "timeout=60"]),
			.wait(condition: "model-loaded", arguments: ["id": "abc"], timeout: 60)
		)
		XCTAssertEqual(try HeadlessCommandLine.parse(["perform", "note", "text=a=b"]), .perform(action: "note", arguments: ["text": "a=b"]))
	}

	func testMistakesAreErrors() {
		for words in [[], ["teleport"], ["goto"], ["goto", "a", "b"], ["state", "x"], ["perform"], ["perform", "a", "b"], ["wait", "c", "timeout=soon"]] {
			XCTAssertThrowsError(try HeadlessCommandLine.parse(words), "\(words)")
		}
	}
}

final class SimulatorSettlingTests: XCTestCase {

	private struct Flake: Error, Equatable {
		let attempt: Int
	}

	func testASucceedingStepRunsOnce() async throws {
		var calls = 0
		var retries: [Int] = []
		let value = try await SimulatorSettling.retrying(attempts: 5, delay: .zero, onRetry: { attempt, _ in retries.append(attempt) }) {
			calls += 1
			return "ok"
		}
		XCTAssertEqual(value, "ok")
		XCTAssertEqual(calls, 1)
		XCTAssertEqual(retries, [])
	}

	func testAStepIsRetriedUntilItSucceedsAndEachFailureIsReported() async throws {
		var calls = 0
		var retries: [Int] = []
		let value = try await SimulatorSettling.retrying(attempts: 5, delay: .zero, onRetry: { attempt, error in
			XCTAssertEqual(error as? Flake, Flake(attempt: attempt))
			retries.append(attempt)
		}) {
			calls += 1
			if calls < 3 { throw Flake(attempt: calls) }
			return calls
		}
		XCTAssertEqual(value, 3)
		XCTAssertEqual(retries, [1, 2])
	}

	func testTheLastAttemptsErrorIsThrownAfterTheBound() async {
		var calls = 0
		var retries: [Int] = []
		do {
			_ = try await SimulatorSettling.retrying(attempts: 3, delay: .zero, onRetry: { attempt, _ in retries.append(attempt) }) { () async throws -> Int in
				calls += 1
				throw Flake(attempt: calls)
			}
			XCTFail("expected the step's error")
		} catch {
			XCTAssertEqual(error as? Flake, Flake(attempt: 3))
		}
		XCTAssertEqual(calls, 3)
		XCTAssertEqual(retries, [1, 2], "the last failure is thrown, not reported as a retry")
	}
}

final class HeadlessSimulatorChoiceTests: XCTestCase {

	private let runtimes = Data(#"""
	{ "runtimes": [
	  { "identifier": "rt.iOS-28-0", "version": "28.0", "platform": "iOS", "isAvailable": true,
	    "supportedDeviceTypes": [ { "identifier": "dt.iPhone-19", "productFamily": "iPhone", "minRuntimeVersion": 1835008 } ] },
	  { "identifier": "rt.iOS-27-0", "version": "27.0", "platform": "iOS", "isAvailable": true,
	    "supportedDeviceTypes": [
	      { "identifier": "dt.iPhone-6s", "productFamily": "iPhone", "minRuntimeVersion": 589824 },
	      { "identifier": "dt.iPhone-18-Pro", "productFamily": "iPhone", "minRuntimeVersion": 1769472 },
	      { "identifier": "dt.iPad-Pro", "productFamily": "iPad", "minRuntimeVersion": 1900000 }
	    ] },
	  { "identifier": "rt.watchOS-12-0", "version": "12.0", "platform": "watchOS", "isAvailable": true, "supportedDeviceTypes": [] },
	  { "identifier": "rt.iOS-26-0", "version": "26.0", "platform": "iOS", "isAvailable": false, "supportedDeviceTypes": [] }
	] }
	"""#.utf8)

	func testTheNewestDrivableRuntimeAndItsNewestIPhone() throws {
		let choice = try HeadlessSimulatorChoice.choose(runtimesJSON: runtimes, sdkVersion: "27.2")
		XCTAssertEqual(choice, .init(runtimeIdentifier: "rt.iOS-27-0", deviceTypeIdentifier: "dt.iPhone-18-Pro"))
	}

	func testNoDrivableRuntimeIsAnError() {
		XCTAssertThrowsError(try HeadlessSimulatorChoice.choose(runtimesJSON: runtimes, sdkVersion: "25.0"))
	}
}
