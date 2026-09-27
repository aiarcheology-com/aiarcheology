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

	/// Every launch selects headless mode first (AIA-0991): without it the Debug app starts its UI and
	/// the launcher waits for an endpoint that never appears.
	func testProcessArgumentsStartWithTheHeadlessInterface() throws {
		XCTAssertEqual(try make([:]).processArguments, ["-interface", "headless"])
		let launch = try make(["mockSubscription": "subscribed", "flags": ["isPaymentsEnabled": true]])
		XCTAssertEqual(Array(launch.processArguments.prefix(2)), ["-interface", "headless"])
		XCTAssertEqual(Array(launch.processArguments.dropFirst(2)), launch.arguments)
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

	func testFreeAccessEndsInFollowsTheFlagsAndPrecedesTheStagedImages() throws {
		let launch = try make([
			"stage": ["images/site.png"],
			"freeAccessEndsIn": 90,
			"flags": ["isPaymentsEnabled": true],
			"mockSubscription": "notSubscribed"
		])
		XCTAssertEqual(launch.arguments, [
			"-mockSubscription", "notSubscribed",
			"-headlessFlag", "isPaymentsEnabled=true",
			"-headlessFreeAccessEndsIn", "90",
			"-headlessStagedImage", "site.png"
		])
		XCTAssertEqual(try make(["freeAccessEndsIn": 30]).arguments, ["-headlessFreeAccessEndsIn", "30"])
		XCTAssertEqual(try make(["freeAccessEndsIn": 3600]).arguments, ["-headlessFreeAccessEndsIn", "3600"])
	}

	func testFreeAccessEndsInMustBeWholeSecondsInRange() {
		for value: JSONValue in [29, 3601, 0, -60, 90.5, "90", true, [90]] {
			XCTAssertEqual(
				rejection(["freeAccessEndsIn": value]),
				"freeAccessEndsIn must be whole seconds within 30...3600, got \(value.jsonString)",
				value.jsonString
			)
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

	/// A scratch directory the root check takes for the repository root.
	private func makeRepositoryRoot() throws {
		try FileManager.default.createDirectory(
			at: scratch.appendingPathComponent(HeadlessRepositoryRoot.marker),
			withIntermediateDirectories: true
		)
	}

	func testOutsideTheRepositoryRootItSaysSoBeforeLookingAtTheMap() throws {
		// A usable map, but no workspace: the directory is still not the root.
		_ = try write(#"{"routes": [{"route": "home", "summary": "Home.", "transitions": []}]}"#, to: HeadlessRouteLint.mapPath)
		XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch)) { error in
			XCTAssertTrue(error is HeadlessRepositoryRoot.NotTheRoot, "\(error)")
			XCTAssertTrue("\(error)".contains("run from the repository root"), "\(error)")
		}
		// Not even a map: still the root error, not the map's.
		try FileManager.default.removeItem(at: scratch)
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch)) { error in
			XCTAssertTrue(error is HeadlessRepositoryRoot.NotTheRoot, "\(error)")
		}
		XCTAssertNoThrow(try HeadlessRepositoryRoot.require(Self.repository))
	}

	func testAMissingMapFailsAndSaysHowToRegenerateIt() throws {
		try makeRepositoryRoot()
		XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch)) { error in
			let text = "\(error)"
			XCTAssertTrue(error is HeadlessRouteLint.MapUnavailable, text)
			XCTAssertTrue(text.contains("ios/HeadlessScenarios/Map/navigation-map.json"), text)
			XCTAssertTrue(text.contains("HeadlessNavigationMapTests"), text)
		}
	}

	func testAnUndecodableOrEmptyMapFails() throws {
		try makeRepositoryRoot()
		for content in [#"{"routes": "#, #"{"routes": []}"#] {
			_ = try write(content, to: HeadlessRouteLint.mapPath)
			XCTAssertThrowsError(try HeadlessRouteLint(repositoryRoot: scratch), content) { error in
				XCTAssertTrue("\(error)".contains("HeadlessNavigationMapTests"), "\(error)")
			}
		}
	}

	/// A file that does not load and one that names an undeclared route are both rejected, and the
	/// others still run, in order.
	func testOneFailingFileDoesNotStopTheOthers() throws {
		let lint = HeadlessRouteLint(map: NavigationMap(routes: [RouteDeclaration(route: "home", summary: "Home.")]))
		func scenario(_ name: String, route: String) throws -> URL {
			try write(#"""
			{ "schemaVersion": 1, "name": "\#(name)", "installations": { "a": {} }, "steps": [ { "goto": "\#(route)" } ] }
			"""#, to: "\(name).json")
		}
		let files = [
			try scenario("first", route: "home"),
			try write(#"{"schemaVersion": 1, "name": "x", "installations": {"a": {}}, "stepz": []}"#, to: "bad.json"),
			try scenario("typo", route: "hme"),
			try scenario("last", route: "home")
		]
		let plan = HeadlessTestPlan(lint.check(files))
		XCTAssertEqual(plan.runnable.map(\.name), ["first", "last"])
		XCTAssertEqual(plan.rejected.map(\.name), ["bad.json", "typo"])
		XCTAssertEqual(plan.rejected.map(\.failures.count), [1, 1], "each rejection carries its lines")
		XCTAssertTrue(plan.rejected[1].failures[0].contains("goto route 'hme' is not a route of this app"), "\(plan.rejected[1].failures)")

		let nothingLeft = HeadlessTestPlan(lint.check([files[1], files[2]]))
		XCTAssertTrue(nothingLeft.runnable.isEmpty, "nothing to build for")
		XCTAssertEqual(nothingLeft.rejected.count, 2)
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

	func testEachOutcomeHasItsOwnMarkAndASkipIsNeitherAPassNorAWarning() {
		func step(failures: [String] = [], bestEffort: Bool = false, skipped: Bool = false) -> StepReport {
			StepReport(phase: "teardown", index: 0, name: nil, installation: "a", command: "perform", route: "home",
				failures: failures, bestEffort: bestEffort, skipped: skipped)
		}
		XCTAssertEqual(HeadlessReportText.mark(for: step()), "✓")
		XCTAssertEqual(HeadlessReportText.mark(for: step(skipped: true)), "–")
		XCTAssertEqual(HeadlessReportText.mark(for: step(bestEffort: true, skipped: true)), "–")
		XCTAssertEqual(HeadlessReportText.mark(for: step(failures: ["x"], bestEffort: true)), "⚠︎")
		XCTAssertEqual(HeadlessReportText.mark(for: step(failures: ["x"])), "✗")
	}

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

	/// The committed scenario files, failing closed: an empty scan means the directory moved, not that
	/// the policy holds.
	private func scenarioFiles() throws -> [URL] {
		let directory = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("../../../ios/HeadlessScenarios")
			.standardizedFileURL
		let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		XCTAssertGreaterThanOrEqual(files.count, 15, "Expected the committed scenarios in \(directory.path).")
		return files
	}

	private func launchBlocks() throws -> [(scenario: String, installation: String, launch: [String: Any])] {
		let files = try scenarioFiles()
		var blocks: [(String, String, [String: Any])] = []
		for file in files {
			let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
			let installations = try XCTUnwrap((object as? [String: Any])?["installations"] as? [String: Any], file.lastPathComponent)
			for (name, value) in installations {
				let launch = (value as? [String: Any])?["launch"] as? [String: Any] ?? [:]
				blocks.append((file.lastPathComponent, name, launch))
			}
		}
		return blocks
	}

	/// Real StoreKit is the default, and a scenario runs the app the way a new user meets it. The
	/// mock stays a manual `up` option only.
	func testNoCommittedScenarioMocksTheSubscription() throws {
		for block in try launchBlocks() {
			XCTAssertNil(block.launch["mockSubscription"], "\(block.scenario) installation \(block.installation) uses -mockSubscription")
		}
	}

	/// AIA-0990: a green run prints no warning for a cleanup that had nothing to do. Every best-effort
	/// teardown action therefore says when it has nothing to do, with `unless`. Navigation (`goto`)
	/// is exempt — reaching the current route is already a no-op — and so is the advisory
	/// `usage.used == 0` observation, which sends nothing and whose warning is a real signal.
	func testEveryBestEffortTeardownActionSaysWhenItHasNothingToDo() throws {
		for file in try scenarioFiles() {
			let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
			let teardown = object["teardown"] as? [[String: Any]] ?? []
			for (index, step) in teardown.enumerated() {
				let location = "\(file.lastPathComponent) teardown[\(index)]"
				if step["bestEffort"] as? Bool == true && step["perform"] != nil {
					XCTAssertNotNil(step["unless"], "\(location) is a best-effort action without unless")
				}
				// Only predicates that fail safe on a typo: a misspelt `equals` never holds, and a
				// misspelt `notRoute` fails the route check. A negated `matches` would skip silently.
				for predicate in step["unless"] as? [[String: Any]] ?? [] {
					XCTAssertTrue(Set(predicate.keys).isSubset(of: ["equals", "notRoute"]), "\(location) unless uses \(predicate.keys.sorted())")
				}
			}
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
