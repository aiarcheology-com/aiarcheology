//
//  HeadlessTests.swift
//  ProjectToolCoreTests
//
//  AIA-0970.
//

import Foundation
import HeadlessKit
import HeadlessScenario
import HeadlessSimulatorLauncher
import XCTest
@testable import ProjectToolCore

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

	private func make(_ options: JSONValue, root: URL? = nil) throws -> HeadlessLaunchPlan {
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
		XCTAssertEqual(try make([:]), HeadlessLaunchPlan(arguments: [], stagedImages: []))
	}

	/// AIA-0994: the audit switch is a run option, added by the kit's launcher; a scenario cannot set it.
	func testTheAppMovesSwitchIsARunOptionOnly() throws {
		XCTAssertEqual(rejection(["appMoves": "off"]), "unknown launch option(s): appMoves", "not a scenario launch key")
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

/// `headless.sh build` is `unittest.sh`'s build (AIA-0991): if the two argument lists drift, each
/// recompiles or relinks the other's app, or they build into different DerivedData.
final class HeadlessBuildTests: XCTestCase {

	private static let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../..")
		.standardizedFileURL

	/// `XCODEBUILD_ARGS=( … )` in `scripts/unittest.sh`, one token per element, quotes removed.
	private func unittestArguments() throws -> [String] {
		let script = try String(contentsOf: Self.repository.appendingPathComponent("scripts/unittest.sh"), encoding: .utf8)
		let start = try XCTUnwrap(script.range(of: "XCODEBUILD_ARGS=(\n"), "unittest.sh no longer declares XCODEBUILD_ARGS")
		let end = try XCTUnwrap(script.range(of: "\n)", range: start.upperBound..<script.endIndex))
		return script[start.upperBound..<end.lowerBound]
			.split(separator: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
			.flatMap { line -> [String] in
				// `-destination "platform=…"` is one element with a quoted value.
				if let space = line.firstIndex(of: " ") {
					return [String(line[..<space]), String(line[line.index(after: space)...]).replacingOccurrences(of: "\"", with: "")]
				}
				return [line]
			}
	}

	func testSharedArgumentsAreUnittestShsExceptActionDestinationAndDerivedData() throws {
		var arguments = try unittestArguments()
		XCTAssertEqual(arguments.first, "test", "unittest.sh's action changed; headless.sh build must follow it")
		arguments.removeFirst()
		for option in ["-destination", "-derivedDataPath"] {
			let index = try XCTUnwrap(arguments.firstIndex(of: option), "unittest.sh no longer passes \(option)")
			arguments.removeSubrange(index...arguments.index(after: index))
		}
		XCTAssertEqual(arguments, HeadlessBuild.unittestSharedArguments)
	}

	func testDefaultDerivedDataIsUnittestShs() throws {
		let script = try String(contentsOf: Self.repository.appendingPathComponent("scripts/unittest.sh"), encoding: .utf8)
		XCTAssertTrue(
			script.contains("DERIVED_DATA=\"${DERIVED_DATA_PATH:-${REPO_ROOT}/\(HeadlessBuild.defaultDerivedData)}\""),
			"unittest.sh's DerivedData default changed; headless.sh build must follow it"
		)
	}

	func testXcodebuildArguments() {
		XCTAssertEqual(
			HeadlessBuild.xcodebuildArguments(destinationUDID: "UDID", derivedData: "/r/.deriveddata", packageCache: nil),
			["build-for-testing"] + HeadlessBuild.unittestSharedArguments + [
				"-configuration", "Debug",
				"-destination", "platform=iOS Simulator,id=UDID",
				"-derivedDataPath", "/r/.deriveddata",
				"-quiet"
			]
		)
		XCTAssertEqual(
			HeadlessBuild.xcodebuildArguments(destinationUDID: "UDID", derivedData: "/r/.deriveddata", packageCache: "/cache").suffix(2),
			["-clonedSourcePackagesDirPath", "/cache"]
		)
		XCTAssertFalse(HeadlessBuild.xcodebuildArguments(destinationUDID: "UDID", derivedData: "/r/.deriveddata", packageCache: "").contains("-clonedSourcePackagesDirPath"))
	}

	func testBuildsUsingFindsOnlyXcodebuildOnTheSameDerivedData() {
		let ps = """
		/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -workspace ios/MLBrowser.xcworkspace -derivedDataPath /r/.deriveddata -testPlan MLBrowserUnitTests
		xcodebuild build -derivedDataPath /r/.deriveddata/ -scheme MLBrowser
		/usr/bin/xcodebuild build -derivedDataPath /r/.deriveddata-localization
		/bin/zsh -c xcodebuild test -derivedDataPath /r/.deriveddata
		/usr/bin/grep -derivedDataPath /r/.deriveddata
		/usr/bin/xcodebuild -version
		"""
		XCTAssertEqual(HeadlessBuild.buildsUsing(derivedData: "/r/.deriveddata", psOutput: ps).count, 2)
		XCTAssertEqual(HeadlessBuild.buildsUsing(derivedData: "/r/other", psOutput: ps), [])
	}
}

/// ML Browser's `HeadlessProject` (AIA-1008): what the kit's commands know about the app.
final class MLBrowserHeadlessTests: XCTestCase {

	private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MLBrowserHeadlessTests-\(UUID().uuidString)")

	/// The checkout this file lives in; a macOS package test runs from it.
	private static let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../..")
		.standardizedFileURL

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: scratch) // Some tests never create it.
	}

	private func project(
		root: URL = MLBrowserHeadlessTests.repository,
		environment: [String: String] = [:],
		runTool: @escaping @Sendable (String, [String]) throws -> Int32 = { _, _ in 0 },
		processList: @escaping @Sendable () throws -> String = { "" }
	) -> MLBrowserHeadless {
		MLBrowserHeadless(root: root, environment: environment, runTool: runTool, processList: processList)
	}

	// MARK: - Paths

	func testTheAppIsUnittestShsDebugBuild() {
		let root = URL(fileURLWithPath: "/repo")
		XCTAssertEqual(project(root: root).app.path, "/repo/.deriveddata/Build/Products/Debug-iphonesimulator/ML Browser.app")
		XCTAssertEqual(project(root: root, environment: ["DERIVED_DATA_PATH": ""]).app.path, "/repo/.deriveddata/Build/Products/Debug-iphonesimulator/ML Browser.app", "empty is unset")
		XCTAssertEqual(project(root: root, environment: ["DERIVED_DATA_PATH": "/dd"]).app.path, "/dd/Build/Products/Debug-iphonesimulator/ML Browser.app")
	}

	func testTheProjectsFixedValues() throws {
		let project = project(root: URL(fileURLWithPath: "/repo"))
		XCTAssertEqual(project.bundleIdentifier, "com.aiarcheology.ios")
		XCTAssertEqual(project.devicePrefix, "aia-headless-")
		XCTAssertEqual(project.invocation, "scripts/headless.sh")
		XCTAssertEqual(project.scenariosDirectory.path, "/repo/ios/HeadlessScenarios")
		XCTAssertEqual(project.navigationMap?.path, "/repo/ios/HeadlessScenarios/Map/navigation-map.json")
	}

	// MARK: - Working directory and the map

	func testOutsideTheRepositoryRootItSaysSoBeforeLookingAtTheMap() async throws {
		// A usable map, but no workspace: the directory is still not the root.
		let map = scratch.appendingPathComponent(MLBrowserHeadless.navigationMapPath)
		try FileManager.default.createDirectory(at: map.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(#"{"routes": [{"route": "home", "summary": "Home.", "transitions": []}]}"#.utf8).write(to: map)
		XCTAssertThrowsError(try project(root: scratch).validateWorkingDirectory()) { error in
			XCTAssertTrue(error is HeadlessRepositoryRoot.NotTheRoot, "\(error)")
			XCTAssertTrue("\(error)".contains("run from the repository root"), "\(error)")
		}
		// Not even a map: the kit's `test --lint` still reports the root, not the map.
		try FileManager.default.removeItem(at: map)
		do {
			try await HeadlessTool.run(["test", "--lint"], project: project(root: scratch))
			XCTFail("ran outside the repository root")
		} catch {
			XCTAssertTrue(error is HeadlessRepositoryRoot.NotTheRoot, "\(error)")
			XCTAssertEqual(HeadlessTool.exitCode(for: error), 1)
		}
		XCTAssertNoThrow(try project().validateWorkingDirectory())
	}

	/// Every committed scenario names only routes the committed map declares.
	func testEveryCommittedScenarioPassesAgainstTheCommittedMap() throws {
		let project = project()
		let lint = try HeadlessRouteLint(mapFile: try XCTUnwrap(project.navigationMap))
		let files = try FileManager.default.contentsOfDirectory(at: project.scenariosDirectory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		// Fail closed: an empty scan means the directory moved, not that the scenarios pass.
		XCTAssertGreaterThanOrEqual(files.count, 15)
		for outcome in lint.check(files) {
			XCTAssertTrue(outcome.passed, "\(outcome)")
		}
	}

	// MARK: - The handshake

	private func metadata(backend: JSONValue? = "development", crashReporting: JSONValue? = false, appMoves: JSONValue? = "oneHop") -> [String: JSONValue] {
		var metadata: [String: JSONValue] = [:]
		metadata["backendEnvironment"] = backend
		metadata["crashReporting"] = crashReporting
		if let appMoves { metadata["launchOptions"] = ["appMoves": appMoves] }
		return metadata
	}

	func testADevelopmentAppWithoutACrashReporterOnTheRunsRuleIsAccepted() throws {
		XCTAssertNil(MLBrowserHeadless.refusal(of: metadata(), appMoves: .oneHop))
		XCTAssertNil(MLBrowserHeadless.refusal(of: metadata(appMoves: "off"), appMoves: .off))
		XCTAssertNoThrow(try project().accept(ServerHello(metadata: metadata()), appMoves: .oneHop))
	}

	func testEachRefusalInOrderWithItsMessage() {
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(backend: "production", crashReporting: true, appMoves: nil), appMoves: .oneHop),
			#"the headless app reports backend "production"; refusing to drive anything but development"#
		)
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(backend: nil), appMoves: .oneHop),
			"the headless app reports backend none; refusing to drive anything but development"
		)
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(crashReporting: true, appMoves: nil), appMoves: .oneHop),
			"the headless app reports crashReporting true; headless mode must run without a crash reporter, so refusing to drive it"
		)
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(crashReporting: nil), appMoves: .oneHop),
			"the headless app reports crashReporting unknown; headless mode must run without a crash reporter, so refusing to drive it"
		)
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(appMoves: "oneHop"), appMoves: .off),
			#"the headless app reports appMoves "oneHop", not off; rebuild it (scripts/headless.sh build)"#
		)
		XCTAssertEqual(
			MLBrowserHeadless.refusal(of: metadata(appMoves: nil), appMoves: .oneHop),
			"the headless app reports appMoves none, not oneHop; rebuild it (scripts/headless.sh build)"
		)
	}

	func testARefusalIsAUsageError() {
		XCTAssertThrowsError(try project().accept(ServerHello(metadata: metadata(backend: "production")), appMoves: .oneHop)) { error in
			XCTAssertTrue(error is HeadlessUsageError, "\(error)")
			XCTAssertEqual(HeadlessTool.exitCode(for: error), 64)
		}
	}

	// MARK: - `up` options

	private func launch(_ values: [(option: String, value: String)]) throws -> [String: JSONValue] {
		let options = project().upOptions
		var launch: [String: JSONValue] = [:]
		for (name, value) in values {
			try XCTUnwrap(options.first { $0.name == name }, name).apply(&launch, value)
		}
		return launch
	}

	func testUpOptionsFillTheLaunchBlockAScenarioHolds() throws {
		XCTAssertEqual(project().upOptions.map(\.name), ["mock-subscription", "flag", "free-access-ends-in", "image"])
		XCTAssertEqual(project().upOptions.map(\.isRepeatable), [false, true, false, true])
		let block = try launch([
			("mock-subscription", "subscribed"),
			("flag", "isPaymentsEnabled=true"),
			("flag", "isFreeAccessPeriodEnabled=false"),
			("free-access-ends-in", "90"),
			("image", "ios/a.png"),
			("image", "ios/b.jpg")
		])
		XCTAssertEqual(JSONValue.object(block), [
			"mockSubscription": "subscribed",
			"flags": ["isPaymentsEnabled": true, "isFreeAccessPeriodEnabled": false],
			"freeAccessEndsIn": 90,
			"stage": ["ios/a.png", "ios/b.jpg"]
		])
		XCTAssertEqual(try launch([]), [:], "no option, no key")
	}

	func testUnusableUpValuesAreUsageErrors() {
		let cases: [(option: String, value: String, message: String)] = [
			("flag", "isPaymentsEnabled", "--flag expects key=true|false, got 'isPaymentsEnabled'"),
			("flag", "isPaymentsEnabled=yes", "--flag expects key=true|false, got 'isPaymentsEnabled=yes'"),
			("free-access-ends-in", "1.5", "--free-access-ends-in expects whole seconds, got '1.5'"),
			("free-access-ends-in", "soon", "--free-access-ends-in expects whole seconds, got 'soon'")
		]
		for (option, value, message) in cases {
			XCTAssertThrowsError(try launch([(option, value)]), value) { error in
				XCTAssertTrue(error is HeadlessUsageError, "\(error)")
				XCTAssertEqual("\(error)", message)
			}
		}
	}

	// MARK: - Launch preparation

	func testPrepareLaunchStagesOnlyWhenTheBlockListsImages() throws {
		let plain = try project().prepareLaunch(["mockSubscription": "subscribed"])
		XCTAssertEqual(plain.arguments, ["-mockSubscription", "subscribed"])
		XCTAssertNil(plain.stage, "nothing to stage: the container is not looked up")
		XCTAssertThrowsError(try project().prepareLaunch(["appMoves": "off"]))

		let repository = scratch.appendingPathComponent("repo")
		try FileManager.default.createDirectory(at: repository.appendingPathComponent("images"), withIntermediateDirectories: true)
		try Data("new".utf8).write(to: repository.appendingPathComponent("images/site.png"))
		let container = scratch.appendingPathComponent("container")
		let staged = container.appendingPathComponent(HeadlessDevice.stagedImagesPath).appendingPathComponent("site.png")
		try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("old".utf8).write(to: staged)

		let preparation = try project(root: repository).prepareLaunch(["stage": ["images/site.png"]])
		XCTAssertEqual(preparation.arguments, ["-headlessStagedImage", "site.png"])
		try XCTUnwrap(preparation.stage)(container)
		XCTAssertEqual(try Data(contentsOf: staged), Data("new".utf8), "a staged file of the same name is replaced")
	}

	// MARK: - Build

	/// The fixture fetch, then the destination (only after the preflight), then xcodebuild.
	func testTheBuildRunsInUnittestShsOrder() async throws {
		let calls = Calls()
		let project = project(environment: ["DERIVED_DATA_PATH": "/dd", "SPM_CACHE_PATH": "/spm"], runTool: { command, arguments in
			calls.append(([command] + arguments).joined(separator: " "))
			return 0
		})
		try await project.build(destination: {
			calls.append("destination")
			return "UDID"
		})
		XCTAssertEqual(calls.all, [
			"scripts/fetch_apple_test_models.sh",
			"destination",
			(["xcodebuild"] + HeadlessBuild.xcodebuildArguments(destinationUDID: "UDID", derivedData: "/dd", packageCache: "/spm")).joined(separator: " ")
		])
	}

	func testAFailedBuildStepSaysWhichAndStops() async throws {
		let calls = Calls()
		let project = project(runTool: { command, _ in
			calls.append(command)
			return command == "xcodebuild" ? 65 : 0
		})
		do {
			try await project.build(destination: { "UDID" })
			XCTFail("the build passed")
		} catch {
			XCTAssertEqual("\(error)", "xcodebuild failed with exit code 65")
		}
		let fetchFails = self.project(runTool: { _, _ in 3 })
		do {
			try await fetchFails.build(destination: { XCTFail("no destination after a failed fetch"); return "" })
			XCTFail("the build passed")
		} catch {
			XCTAssertEqual("\(error)", "scripts/fetch_apple_test_models.sh failed with exit code 3")
		}
	}

	func testABuildOnTheSharedDerivedDataRefusesBuildAndInstall() async throws {
		let project = project(
			environment: ["DERIVED_DATA_PATH": "/dd"],
			runTool: { _, _ in XCTFail("nothing may run"); return 0 },
			processList: { "/usr/bin/xcodebuild test -derivedDataPath /dd\n" }
		)
		let message = "another xcodebuild is using /dd; wait for it to finish (headless mode shares unittest.sh's DerivedData)"
		do {
			try await project.build(destination: { XCTFail("no destination"); return "" })
			XCTFail("the build ran")
		} catch {
			XCTAssertTrue(error is HeadlessUsageError, "\(error)")
			XCTAssertEqual("\(error)", message)
		}
		XCTAssertThrowsError(try project.willInstall()) { error in
			XCTAssertTrue(error is HeadlessUsageError, "\(error)")
			XCTAssertEqual("\(error)", message)
		}
	}

	func testOnlyADevelopmentProductIsInstalled() throws {
		let app = scratch.appendingPathComponent("dd/Build/Products/Debug-iphonesimulator/ML Browser.app")
		try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let project = project(root: scratch, environment: ["DERIVED_DATA_PATH": scratch.appendingPathComponent("dd").path])
		for (backend, accepted) in [("development", true), ("production", false)] {
			let plist = try PropertyListSerialization.data(fromPropertyList: ["BackendEnvironment": backend], format: .xml, options: 0)
			try plist.write(to: app.appendingPathComponent("Info.plist"))
			if accepted {
				XCTAssertNoThrow(try project.willInstall())
			} else {
				XCTAssertThrowsError(try project.willInstall()) { error in
					XCTAssertTrue(error is HeadlessUsageError, "\(error)")
					XCTAssertEqual("\(error)", "the Debug build at \(app.path) is for the production backend; headless mode exists only in a development build")
				}
			}
		}
	}
}

/// What a fake tool was asked to run, in order.
private final class Calls: @unchecked Sendable {
	// @unchecked: the build calls its tools one at a time, on one task.
	private let lock = NSLock()
	private var calls: [String] = []

	func append(_ call: String) {
		lock.withLock { calls.append(call) }
	}

	var all: [String] {
		lock.withLock { calls }
	}
}
