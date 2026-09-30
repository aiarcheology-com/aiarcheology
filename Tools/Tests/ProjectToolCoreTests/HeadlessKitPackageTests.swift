//
//  HeadlessKitPackageTests.swift
//  ProjectToolCoreTests
//
//  AIA-1005.
//

import Foundation
import XCTest

/// HeadlessKit lives in its own repository (aiarcheology-com/HeadlessKit) since AIA-1005. The app
/// and ProjectTool each pin it, so these tests keep the two pins equal and the kit's code out of
/// this repository.
final class HeadlessKitPackageTests: XCTestCase {

	/// The checkout this file lives in; a macOS package test runs from it.
	private static let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../..")
		.standardizedFileURL

	private static let url = "https://github.com/aiarcheology-com/HeadlessKit.git"

	/// Every Package.resolved that resolves HeadlessKit. The tool and the app speak one wire
	/// protocol only while they resolve the same revision.
	private static let resolvedFiles = [
		"Tools/Package.resolved",
		"ios/MLBrowser.xcworkspace/xcshareddata/swiftpm/Package.resolved",
		"ios/MLBrowser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
	]

	private struct Pin: Equatable {
		let location: String
		let revision: String
		let version: String
	}

	private func text(_ relativePath: String) throws -> String {
		try String(contentsOf: Self.repository.appendingPathComponent(relativePath), encoding: .utf8)
	}

	private func headlessKitPin(in relativePath: String) throws -> Pin {
		let data = try Data(contentsOf: Self.repository.appendingPathComponent(relativePath))
		let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
		let pins = try XCTUnwrap(root["pins"] as? [[String: Any]], "\(relativePath) has no pins")
		let pin = try XCTUnwrap(pins.first { $0["identity"] as? String == "headlesskit" }, "\(relativePath) does not pin headlesskit")
		let state = try XCTUnwrap(pin["state"] as? [String: Any], "\(relativePath): headlesskit has no state")
		return Pin(
			location: try XCTUnwrap(pin["location"] as? String),
			revision: try XCTUnwrap(state["revision"] as? String),
			version: try XCTUnwrap(state["version"] as? String, "\(relativePath): headlesskit is not pinned to a version")
		)
	}

	func testTheAppAndTheToolResolveTheSameHeadlessKit() throws {
		let pins = try Self.resolvedFiles.map { try headlessKitPin(in: $0) }
		let tool = pins[0]
		XCTAssertEqual(tool.location, Self.url)
		for (file, pin) in zip(Self.resolvedFiles, pins).dropFirst() {
			XCTAssertEqual(pin, tool, "\(file) resolves another HeadlessKit than Tools/Package.resolved. Bump both pins, then resolve both.")
		}

		// The manifests ask for exactly the version that is resolved, so a resolve cannot drift.
		let dependencies = try toolsManifestDependencies(on: Self.url)
		XCTAssertEqual(dependencies.count, 1, "Tools/Package.swift must depend on \(Self.url) exactly once")
		let dependency = dependencies.first ?? ""
		let exact = try Regex(#"exact:\s*"([^"]+)""#)
		let manifestVersions = dependency.matches(of: exact).map { String($0.output[1].substring ?? "") }
		XCTAssertEqual(manifestVersions, [tool.version], "Tools/Package.swift must pin HeadlessKit with exact: \"\(tool.version)\"")

		// Since 0.2.0 the kit compiles only under `DEBUG || HeadlessHost` (AIA-1006). Without the trait
		// a `-c release` ProjectTool loses the client and the runner, and nothing routine builds one.
		let traits = try Regex(#"traits:\s*\[([^\]]*)\]"#)
		let enabledTraits = dependency.matches(of: traits).map { String($0.output[1].substring ?? "") }
		XCTAssertEqual(enabledTraits.count, 1, "Tools/Package.swift must enable HeadlessKit's traits once, with traits: [\"HeadlessHost\"]")
		XCTAssertTrue(enabledTraits.first?.contains(#""HeadlessHost""#) == true, "Tools/Package.swift must enable HeadlessKit's HeadlessHost trait")

		let requirements = try projectRequirements(for: Self.url)
		XCTAssertEqual(requirements.count, 1, "The Xcode project must reference \(Self.url) exactly once")
		XCTAssertEqual(requirements.first?["kind"] as? String, "exactVersion", "The Xcode project must pin HeadlessKit to an exact version")
		XCTAssertEqual(requirements.first?["version"] as? String, tool.version, "The Xcode project pins another HeadlessKit version than Tools")
	}

	/// The argument list of every `.package(…)` call in Tools/Package.swift that names `url`, in any
	/// argument order. The arguments hold brackets and strings but no parentheses.
	private func toolsManifestDependencies(on url: String) throws -> [String] {
		let manifest = try text("Tools/Package.swift")
		XCTAssertTrue(manifest.contains(".package("), "Tools/Package.swift was not read.")
		let call = try Regex(#"\.package\(([^()]*"\#(NSRegularExpression.escapedPattern(for: url))"[^()]*)\)"#)
		return manifest.matches(of: call).map { String($0.output[1].substring ?? "") }
	}

	/// The `requirement` of every remote package reference to `url` in the Xcode project, read as the
	/// property list it is rather than by its text layout.
	private func projectRequirements(for url: String) throws -> [[String: Any]] {
		let data = try Data(contentsOf: Self.repository.appendingPathComponent("ios/MLBrowser.xcodeproj/project.pbxproj"))
		let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		let objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]], "project.pbxproj has no objects")
		return objects.values
			.filter { $0["isa"] as? String == "XCRemoteSwiftPackageReference" && $0["repositoryURL"] as? String == url }
			.compactMap { $0["requirement"] as? [String: Any] }
	}

	/// From v0.1.0 on, a change to the kit is a new HeadlessKit version and a pin bump, never an
	/// edit here. A copy in this repository would be built by nothing and silently diverge.
	func testHeadlessKitsCodeStaysInItsOwnRepository() throws {
		let files = FileManager.default
		for directory in ["Sources", "Tests"] {
			let entries = try files.contentsOfDirectory(atPath: Self.repository.appendingPathComponent(directory).path)
			// Fail closed: an empty listing would mean the path is wrong, not that the check passed.
			XCTAssertFalse(entries.isEmpty, "\(directory)/ is empty or missing; the check is broken, not clean.")
			let kit = entries.filter { $0.hasPrefix("HeadlessKit") || $0.hasPrefix("HeadlessScenario") }
			XCTAssertEqual(
				kit, [],
				"\(directory)/ has HeadlessKit code again. Change it in aiarcheology-com/HeadlessKit, release a version and bump both pins."
			)
		}
		let manifest = try text("Package.swift")
		XCTAssertTrue(manifest.contains(#"name: "SupportLogFormat""#), "Package.swift was not read.")
		for product in ["HeadlessKit", "HeadlessKitTransport", "HeadlessScenario"] {
			XCTAssertFalse(manifest.contains(#"name: "\#(product)""#), "Package.swift declares \(product) again.")
		}
	}
}
