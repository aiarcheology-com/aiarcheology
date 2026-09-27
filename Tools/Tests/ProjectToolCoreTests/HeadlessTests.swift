//
//  HeadlessTests.swift
//  ProjectToolCoreTests
//
//  AIA-0970.
//

import Foundation
import HeadlessKit
import HeadlessScenario
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

final class HeadlessStagingDirectoryTests: XCTestCase {

	private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessStagingDirectoryTests-\(UUID().uuidString)")

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: scratch) // Some tests never create it.
	}

	func testTheDirectoryIsCreatedInsideTheContainer() throws {
		let container = scratch.appendingPathComponent("container")
		try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
		let directory = try HeadlessDevice.stagingDirectory(in: container)
		XCTAssertEqual(directory.lastPathComponent, "Staged")
		var isDirectory: ObjCBool = false
		XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
	}

	func testASymlinkedAncestorThatLeavesTheContainerIsRefused() throws {
		let container = scratch.appendingPathComponent("container")
		let elsewhere = scratch.appendingPathComponent("elsewhere")
		try FileManager.default.createDirectory(at: container.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(
			at: container.appendingPathComponent("Library/Application Support/Headless"),
			withDestinationURL: elsewhere
		)
		XCTAssertThrowsError(try HeadlessDevice.stagingDirectory(in: container)) { error in
			XCTAssertTrue(error is HeadlessDevice.StagingOutsideContainer, "\(error)")
		}
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Staged").path),
			"nothing may be created outside the container before the refusal"
		)
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
		// A link inside the repository whose name says image but whose target is not one.
		try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent("images/notes.png"), withDestinationURL: repository.appendingPathComponent("images/notes.txt"))
		XCTAssertEqual(rejection(["stage": ["images/notes.png"]]), "stage entry 'images/notes.png' must be a .png, .jpg or .jpeg image")
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
		for words in [[], ["teleport"], ["goto"], ["goto", "a", "b"], ["state", "x"], ["perform"], ["perform", "a", "b"], ["wait", "c", "timeout=soon"], ["map", "x"]] {
			XCTAssertThrowsError(try HeadlessCommandLine.parse(words), "\(words)")
		}
	}

	private func rejection(_ words: [String]) -> String? {
		do {
			_ = try HeadlessCommandLine.parse(words)
			return nil
		} catch {
			return "\(error)"
		}
	}

	func testMapTakesNoArgumentsAndNamesTheOptionOrder() throws {
		XCTAssertEqual(try HeadlessCommandLine.parse(["map"]), .map)
		// `exec map --format dot`: exec passes the words after the command through verbatim.
		XCTAssertEqual(rejection(["map", "--format", "dot"]), "'map' takes no arguments; options go before the command: exec --format dot map")
		XCTAssertEqual(rejection([]), "expected a command: help, state, actions, map, goto, perform, wait")
	}

	func testDotRendersOnlyTheMap() throws {
		XCTAssertNoThrow(try HeadlessExecFormat.dot.check(.map))
		XCTAssertNoThrow(try HeadlessExecFormat.json.check(.state))
		XCTAssertNoThrow(try HeadlessExecFormat.json.check(.map))
		XCTAssertThrowsError(try HeadlessExecFormat.dot.check(.state)) { error in
			XCTAssertEqual("\(error)", "--format dot renders only the map command: exec --format dot map")
		}
		XCTAssertEqual(HeadlessExecFormat(rawValue: "dot"), .dot)
		XCTAssertNil(HeadlessExecFormat(rawValue: "svg"))
	}
}

final class HeadlessMapDotTests: XCTestCase {

	/// A small `map` result: home is current, with an open, an available, a plain and an
	/// action-less edge, one undeclared live transition to a declared route and one to an unknown one.
	private let result: JSONValue = [
		"guarantee": "possible",
		"current": "home",
		"routes": [
			["route": "launching", "summary": "Starting up.", "current": false, "transitions": [
				["to": "home", "condition": "ready"]
			]],
			["route": "home", "summary": "The \"app\" proper\\main.", "current": true, "transitions": [
				["action": "open-drawer", "to": "drawer", "condition": "always", "open": true],
				["action": "continue", "to": "save-finding", "condition": "a detection\nis held", "available": true],
				["action": "sign-out", "to": "launching", "condition": "signed in"]
			]],
			["route": "drawer", "summary": "The menu.", "current": false, "transitions": []],
			["route": "save-finding", "summary": "Save.", "current": false, "transitions": []]
		],
		"undeclared": [
			["action": "open-settings", "to": "drawer"],
			["action": "teleport", "to": "no-such-route"]
		]
	]

	func testTheGraphMarksCurrentOpenAvailableActionlessAndUndeclared() throws {
		XCTAssertEqual(try HeadlessMapDot.render(result), #"""
		digraph "navigation map" {
			label="Possible transitions, not guaranteed; current: home";
			labelloc=t;
			rankdir=LR;
			node [shape=box, style=rounded, fontname="Helvetica"];
			edge [fontname="Helvetica", fontsize=10];
			"launching" [tooltip="Starting up."];
			"home" [tooltip="The \"app\" proper\\main.", style="rounded,filled,bold", fillcolor="gold"];
			"drawer" [tooltip="The menu."];
			"save-finding" [tooltip="Save."];
			"no-such-route" [color="red", fontcolor="red", tooltip="not a declared route"];
			"launching" -> "home" [label="on its own", style="dashed", fontname="Helvetica-Oblique", tooltip="ready"];
			"home" -> "drawer" [label="open-drawer (open)", color="forestgreen", fontcolor="forestgreen", penwidth="2.5", tooltip="always"];
			"home" -> "save-finding" [label="continue (available)", color="royalblue", fontcolor="royalblue", penwidth="2", tooltip="a detection\nis held"];
			"home" -> "launching" [label="sign-out", tooltip="signed in"];
			"home" -> "drawer" [label="open-settings (undeclared)", color="red", fontcolor="red", style="dashed"];
			"home" -> "no-such-route" [label="teleport (undeclared)", color="red", fontcolor="red", style="dashed"];
		}
		"""#)
	}

	func testTheSameResultRendersTheSameText() throws {
		XCTAssertEqual(try HeadlessMapDot.render(result), try HeadlessMapDot.render(result))
	}

	func testSomethingElseIsNotAMap() {
		for value: JSONValue in [["route": "home"], "map", ["routes": [["summary": "no name"]]], ["routes": [], "undeclared": [["action": "x", "to": "y"]]]] {
			XCTAssertThrowsError(try HeadlessMapDot.render(value), value.jsonString) { error in
				XCTAssertTrue("\(error)".hasPrefix("not a map result"), "\(error)")
			}
		}
	}
}

final class HeadlessRouteLintTests: XCTestCase {

	private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessRouteLintTests-\(UUID().uuidString)")

	/// The checkout this file lives in; a macOS package test runs from it.
	private static let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../..")
		.standardizedFileURL

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: scratch) // Some tests never create it.
	}

	private func write(_ text: String, to path: String) throws -> URL {
		let file = scratch.appendingPathComponent(path)
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(text.utf8).write(to: file)
		return file
	}

	func testATypoIsCaughtWithTheClosestRoute() throws {
		let lint = try HeadlessRouteLint(repositoryRoot: Self.repository)
		let file = try write(#"""
		{
		  "schemaVersion": 1, "name": "typo",
		  "installations": { "a": {} },
		  "steps": [ { "name": "wait for home", "wait": { "condition": "route", "arguments": { "route": "hme" } } } ],
		  "teardown": []
		}
		"""#, to: "typo.json")
		let outcomes = lint.check([file])
		guard case .checked(_, let scenario, let failures) = try XCTUnwrap(outcomes.first) else {
			return XCTFail("the scenario should load: \(outcomes)")
		}
		XCTAssertEqual(scenario.name, "typo")
		XCTAssertEqual(failures.count, 1)
		XCTAssertTrue(
			failures.first?.hasPrefix(#"steps[0] "wait for home": wait route 'hme' is not a route of this app; did you mean 'home'? (known: "#) == true,
			"\(failures)"
		)
		XCTAssertFalse(outcomes[0].passed)
	}

	func testAFileThatDoesNotLoadFails() throws {
		let lint = HeadlessRouteLint(map: NavigationMap(routes: [RouteDeclaration(route: "home", summary: "Home.")]))
		let file = try write(#"{"schemaVersion": 1, "name": "x", "installations": {"a": {}}, "stepz": []}"#, to: "bad.json")
		let outcome = try XCTUnwrap(lint.check([file]).first)
		guard case .unreadable(let failed, _) = outcome else { return XCTFail("\(outcome)") }
		XCTAssertEqual(failed, file)
		XCTAssertFalse(outcome.passed)
	}

	func testAMissingMapFailsAndSaysHowToRegenerateIt() throws {
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch)) { error in
			let text = "\(error)"
			XCTAssertTrue(error is HeadlessRouteLint.MapUnavailable, text)
			XCTAssertTrue(text.contains("ios/HeadlessScenarios/Map/navigation-map.json"), text)
			XCTAssertTrue(text.contains("HeadlessNavigationMapTests"), text)
		}
	}

	func testAnUndecodableOrEmptyMapFails() throws {
		for content in [#"{"routes": "#, #"{"routes": []}"#] {
			_ = try write(content, to: HeadlessRouteLint.mapPath)
			XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch), content) { error in
				XCTAssertTrue("\(error)".contains("HeadlessNavigationMapTests"), "\(error)")
			}
		}
	}

	/// Every committed scenario names only routes the committed map declares.
	func testEveryCommittedScenarioPassesAgainstTheCommittedMap() throws {
		let lint = try HeadlessRouteLint(repositoryRoot: Self.repository)
		let files = try FileManager.default.contentsOfDirectory(
			at: Self.repository.appendingPathComponent("ios/HeadlessScenarios"),
			includingPropertiesForKeys: nil
		)
		.filter { $0.pathExtension == "json" }
		.sorted { $0.lastPathComponent < $1.lastPathComponent }
		// Fail closed: an empty scan means the directory moved, not that the scenarios pass.
		XCTAssertGreaterThanOrEqual(files.count, 15)
		for outcome in lint.check(files) {
			XCTAssertTrue(outcome.passed, "\(outcome)")
		}
	}
}

final class HeadlessReportTextTests: XCTestCase {

	func testEveryLineOfAMultiLineMessageIsIndented() {
		XCTAssertEqual(
			HeadlessReportText.indented(["setup: the scenario names routes the app does not declare:\nsteps[0]: a\nsteps[1]: b", "one line"], by: "   "),
			[
				"   setup: the scenario names routes the app does not declare:",
				"     steps[0]: a",
				"     steps[1]: b",
				"   one line"
			]
		)
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

/// What every committed scenario may put in its `launch` blocks (AIA-0976).
///
/// Reads `ios/HeadlessScenarios/*.json` from the repository this test file lives in, so the policy is
/// checked by the package tests rather than by a grep someone has to remember.
final class HeadlessScenarioPolicyTests: XCTestCase {

	/// The flags that decide how a fresh install enters the app, which every scenario pins: two are
	/// launch-captured with no cached value on a fresh install, the analytics switch is live, and the
	/// identity flag makes the consent question wait on Clerk. See `specification/HEADLESS.md`.
	static let entryFlags = ["isPaymentsEnabled", "isFreeAccessPeriodEnabled", "isAnalyticsEnabled", "isCrossDeviceAnalyticsIdentityEnabled"]

	private func launchBlocks() throws -> [(scenario: String, installation: String, launch: [String: Any])] {
		let directory = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("../../../ios/HeadlessScenarios")
			.standardizedFileURL
		let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		var blocks: [(String, String, [String: Any])] = []
		for file in files {
			let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
			let installations = try XCTUnwrap((object as? [String: Any])?["installations"] as? [String: Any], file.lastPathComponent)
			for (name, value) in installations {
				let launch = (value as? [String: Any])?["launch"] as? [String: Any] ?? [:]
				blocks.append((file.lastPathComponent, name, launch))
			}
		}
		// Fail closed: an empty scan means the directory moved, not that the policy holds.
		XCTAssertGreaterThanOrEqual(files.count, 15, "Expected the committed scenarios in \(directory.path).")
		return blocks
	}

	/// Real StoreKit is the default, and a scenario runs the app the way a new user meets it. The
	/// mock stays a manual `up` option only.
	func testNoCommittedScenarioMocksTheSubscription() throws {
		for block in try launchBlocks() {
			XCTAssertNil(block.launch["mockSubscription"], "\(block.scenario) installation \(block.installation) uses -mockSubscription")
		}
	}

	func testEveryInstallationPinsTheEntryFlags() throws {
		for block in try launchBlocks() {
			let flags = block.launch["flags"] as? [String: Any] ?? [:]
			for key in Self.entryFlags {
				XCTAssertNotNil(flags[key] as? Bool, "\(block.scenario) installation \(block.installation) does not pin \(key)")
			}
		}
	}
}
