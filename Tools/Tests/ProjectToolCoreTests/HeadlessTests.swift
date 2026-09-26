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

	/// A scratch tree per test: `<scratch>/repo` is the repository, `<scratch>/outside` is not.
	/// XCTest makes one instance per test, so each test gets its own directory.
	private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessLaunchArgumentsTests-\(UUID().uuidString)")
	private var repository: URL { scratch.appendingPathComponent("repo") }
	private var outside: URL { scratch.appendingPathComponent("outside") }

	override func setUpWithError() throws {
		try FileManager.default.createDirectory(at: repository.appendingPathComponent("images/nested"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		for path in ["images/site.png", "images/-site.png", "images/aerial.JPG", "images/nested/trench.jpeg", "images/nested/site.png", "images/notes.txt"] {
			try Data("image".utf8).write(to: repository.appendingPathComponent(path))
		}
		try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.png"))
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: scratch)
	}

	private func make(_ options: JSONValue, root: URL? = nil) throws -> HeadlessLaunch {
		try HeadlessLaunchArguments.make(from: options, repositoryRoot: root ?? repository)
	}

	/// The error's description, so each rejection is proven to be for the reason under test.
	private func rejection(_ options: JSONValue, root: URL? = nil) -> String? {
		do {
			_ = try make(options, root: root)
			return nil
		} catch let error as HeadlessLaunchArguments.Invalid {
			return error.description
		} catch {
			return "unexpected \(error)"
		}
	}

	func testOptionsBecomeLaunchArgumentsInAStableOrder() throws {
		let launch = try make([
			"mockSubscription": "subscribed",
			"flags": ["isPaymentsEnabled": true, "isFreeAccessPeriodEnabled": false]
		])
		XCTAssertEqual(launch.arguments, [
			"-mockSubscription", "subscribed",
			"-headlessFlag", "isFreeAccessPeriodEnabled=false",
			"-headlessFlag", "isPaymentsEnabled=true"
		])
		XCTAssertEqual(launch.stagedImages, [])
		XCTAssertEqual(try make([:]), HeadlessLaunch(arguments: [], stagedImages: []))
	}

	func testMistakesAreErrors() {
		let invalid: [JSONValue] = [
			"subscribed",
			["mockSubscriptions": "subscribed"],
			["mockSubscription": "yes"],
			["flags": ["isPaymentsEnabled": "true"]],
			["flags": true],
			["stages": ["images/site.png"]]
		]
		for options in invalid {
			XCTAssertThrowsError(try make(options), options.jsonString)
		}
	}

	func testStagedImagesBecomeNamesInTheListedOrderAfterTheOtherOptions() throws {
		let launch = try make([
			"mockSubscription": "notSubscribed",
			"stage": ["images/nested/trench.jpeg", "images/site.png", "images/aerial.JPG"]
		])
		XCTAssertEqual(launch.arguments, [
			"-mockSubscription", "notSubscribed",
			"-headlessStagedImage", "trench.jpeg",
			"-headlessStagedImage", "site.png",
			"-headlessStagedImage", "aerial.JPG"
		])
		XCTAssertEqual(launch.stagedImages.map(\.name), ["trench.jpeg", "site.png", "aerial.JPG"])
		let resolvedRepository = repository.resolvingSymlinksInPath().path
		for image in launch.stagedImages {
			XCTAssertTrue(image.source.path.hasPrefix(resolvedRepository + "/"), image.source.path)
			XCTAssertTrue(FileManager.default.fileExists(atPath: image.source.path), image.source.path)
		}
		XCTAssertFalse(launch.arguments.contains { $0.contains("/") }, "the app is never handed a host path")
	}

	func testStageMustBeAnArrayOfStrings() {
		XCTAssertEqual(rejection(["stage": "images/site.png"]), "stage must be an array of repository-relative image paths")
		XCTAssertEqual(rejection(["stage": ["images": "site.png"]]), "stage must be an array of repository-relative image paths")
		XCTAssertEqual(rejection(["stage": [1]]), "stage entries must be strings, got 1")
		XCTAssertEqual(rejection(["stage": [["images/site.png"]]])?.hasPrefix("stage entries must be strings"), true)
	}

	func testUnusableEntriesAreRejectedForTheirReason() {
		let cases: [(entry: String, reason: String)] = [
			("", "must be non-empty"),
			(outside.appendingPathComponent("secret.png").path, "must be relative"),
			("../outside/secret.png", "resolves outside the repository"),
			("images/../../outside/secret.png", "resolves outside the repository"),
			("images/missing.png", "does not exist"),
			("images/nested", "is not a regular file"),
			("images/notes.txt", "must be a .png, .jpg or .jpeg image"),
			("images/-site.png", "has a name starting with '-'")
		]
		for (entry, reason) in cases {
			let description = rejection(["stage": [.string(entry)]])
			XCTAssertTrue(description?.contains(reason) == true, "\(entry): \(description ?? "accepted")")
		}
	}

	func testTwoImagesWithOneNameAreRejected() throws {
		XCTAssertEqual(
			rejection(["stage": ["images/site.png", "images/nested/site.png"]]),
			"stage lists more than one image named 'site.png'; the app sees names only"
		)
		XCTAssertEqual(
			rejection(["stage": ["images/site.png", "images/site.png"]]),
			"stage lists more than one image named 'site.png'; the app sees names only"
		)
		// The copies land on a case-insensitive file system, where these are one file.
		try FileManager.default.copyItem(at: repository.appendingPathComponent("images/site.png"), to: repository.appendingPathComponent("SITE.png"))
		XCTAssertEqual(
			rejection(["stage": ["images/site.png", "SITE.png"]]),
			"stage lists more than one image named 'SITE.png'; the app sees names only"
		)
	}

	func testARepositoryReachedThroughASymlinkIsStillTheRepository() throws {
		let link = scratch.appendingPathComponent("repo-link")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository)
		let launch = try make(["stage": ["images/site.png"]], root: link)
		XCTAssertEqual(launch.arguments, ["-headlessStagedImage", "site.png"])
		XCTAssertEqual(launch.stagedImages.first?.source.path, repository.appendingPathComponent("images/site.png").resolvingSymlinksInPath().path)
	}

	func testASymlinkInsideTheRepositoryCannotReachOutsideIt() throws {
		try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent("escape"), withDestinationURL: outside)
		try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent("images/leak.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
		for root in [repository, scratch.appendingPathComponent("repo/.")] {
			XCTAssertEqual(rejection(["stage": ["escape/secret.png"]], root: root), "stage entry 'escape/secret.png' resolves outside the repository")
			XCTAssertEqual(rejection(["stage": ["images/leak.png"]], root: root), "stage entry 'images/leak.png' resolves outside the repository")
		}
		// A sibling whose name merely starts with the repository's is outside it too.
		let sibling = scratch.appendingPathComponent("repo-other")
		try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
		try Data("image".utf8).write(to: sibling.appendingPathComponent("x.png"))
		XCTAssertEqual(rejection(["stage": ["../repo-other/x.png"]]), "stage entry '../repo-other/x.png' resolves outside the repository")
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
