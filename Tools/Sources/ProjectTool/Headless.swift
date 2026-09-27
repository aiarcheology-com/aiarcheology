//
//  Headless.swift
//  ProjectTool
//
//  AIA-0970: build, run and drive the headless ML Browser in the Simulator.
//

import ArgumentParser
import Foundation
import HeadlessKit
import HeadlessKitTransport
import HeadlessScenario
import ProjectToolCore

/// `ProjectTool headless …` — see `specification/HEADLESS.md`.
///
/// Every device it uses is named `aia-headless-<installation>`; it never touches any other.
struct Headless: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "headless",
		abstract: "Build, run and drive the headless ML Browser (AIA-0970).",
		subcommands: [Build.self, Launch.self, Exec.self, Down.self, Reset.self, Test.self]
	)

	struct Build: AsyncParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Build the headless app into .deriveddata-headless.")

		func run() async throws {
			try HeadlessWorkspace.build()
		}
	}

	/// `headless up`.
	struct Launch: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			commandName: "up",
			abstract: "Install and launch the headless app on an installation's own simulator, keeping its data."
		)

		@Option(name: .long, help: "Installation name; the device is aia-headless-<name>.")
		var state: String = "a"

		@Option(name: .long, help: "subscribed or notSubscribed (StoreKit is inert under simctl).")
		var mockSubscription: String?

		@Option(name: .long, help: "Pin a feature flag, key=true|false (repeatable).")
		var flag: [String] = []

		@Option(name: .long, help: "Stage a .png/.jpg/.jpeg from the repository, path relative to its root, in the app's container (repeatable).")
		var image: [String] = []

		func run() async throws {
			var options: [String: JSONValue] = [:]
			if let mockSubscription { options["mockSubscription"] = .string(mockSubscription) }
			var flags: [String: JSONValue] = [:]
			for pin in flag {
				let parts = pin.split(separator: "=", maxSplits: 1).map(String.init)
				guard parts.count == 2, let value = Bool(parts[1]) else {
					throw ValidationError("--flag expects key=true|false, got '\(pin)'")
				}
				flags[parts[0]] = .bool(value)
			}
			if flags.isEmpty == false { options["flags"] = .object(flags) }
			// As a scenario's `stage`, so it gets the same validation and staging.
			if image.isEmpty == false { options["stage"] = .array(image.map(JSONValue.string)) }
			let simulator = try HeadlessSimulator(installation: state)
			let client = try await simulator.launch(options: .object(options), fresh: false, install: true)
			let hello = try await client.connect()
			await client.close()
			print(JSONValue.object(hello.metadata).jsonString)
		}
	}

	struct Exec: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Send one command: help, state, actions, map, goto <route>, perform <action> [k=v…], wait <condition> [k=v…] [timeout=s].",
			discussion: "Options go before the command: everything after it is passed to the app, e.g. exec --format dot map."
		)

		@Option(name: .long, help: "Installation name.")
		var state: String = "a"

		@Option(name: .long, help: "json (the response) or dot (the map result as a Graphviz graph; map only).")
		var format: HeadlessExecFormat = .json

		@Argument(parsing: .captureForPassthrough, help: "The command and its arguments.")
		var command: [String] = []

		func run() async throws {
			let parsed = try HeadlessCommandLine.parse(command)
			// Before anything touches a simulator.
			try format.check(parsed)
			let simulator = try HeadlessSimulator(installation: state)
			let client = HeadlessClient(endpoint: try simulator.readEndpoint())
			let response = try await client.send(parsed)
			await client.close()
			// A failed response prints as JSON whatever the format: its error is the point.
			if format == .dot, response.ok, let result = response.result {
				print(try HeadlessMapDot.render(result))
			} else {
				print(response.document.jsonString)
			}
			if response.ok == false { throw ExitCode.failure }
		}
	}

	struct Down: AsyncParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Quit the app and shut the installation's simulator down, keeping its data.")

		@Option(name: .long, help: "Installation name.")
		var state: String = "a"

		func run() async throws {
			let simulator = try HeadlessSimulator(installation: state)
			try simulator.terminate()
			try simulator.shutdown()
		}
	}

	struct Reset: AsyncParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Erase the installation's simulator: the next launch is a fresh install.")

		@Option(name: .long, help: "Installation name.")
		var state: String = "a"

		func run() async throws {
			try await HeadlessSimulator(installation: state).erase()
		}
	}

	struct Test: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Run scenarios (default: every ios/HeadlessScenarios/*.json), each on fresh installations.",
			discussion: """
			Before building or launching anything, every route a scenario names (goto, wait route, expect \
			route) is checked against the checked-in navigation map, \(HeadlessRouteLint.mapPath). A scenario \
			that does not load or names an undeclared route fails the command there, and nothing is built. \
			That static check is an early filter: the running app's handshake is authoritative, and the \
			runner checks the routes again after each launch. --lint runs the static check alone.
			"""
		)

		@Flag(name: .long, help: "Use the existing headless build instead of building first.")
		var noBuild = false

		@Flag(name: .long, help: "Only check the scenarios' routes against the checked-in navigation map: no build, no simulator.")
		var lint = false

		@Argument(help: "Scenario files.")
		var files: [String] = []

		func run() async throws {
			let paths = files.isEmpty ? try HeadlessWorkspace.defaultScenarios() : files.map { URL(fileURLWithPath: $0) }
			guard paths.isEmpty == false else {
				throw ValidationError("no scenarios found")
			}
			let outcomes = try HeadlessRouteLint(repositoryRoot: HeadlessWorkspace.root).check(paths)
			let failing = outcomes.filter { $0.passed == false }
			if lint {
				outcomes.forEach(Self.printLint)
				guard failing.isEmpty else {
					print("\(failing.count) of \(paths.count) scenario(s) failed the route check.")
					throw ExitCode.failure
				}
				print("All \(paths.count) scenario(s) name only declared routes.")
				return
			}
			guard failing.isEmpty else {
				failing.forEach(Self.printLint)
				print("\(failing.count) of \(paths.count) scenario(s) failed the route check; nothing was built or launched.")
				throw ExitCode.failure
			}
			print("Route check: all \(paths.count) scenario(s) name only declared routes.")
			if noBuild == false {
				try HeadlessWorkspace.build()
			}
			var failed: [String] = []
			var installations: Set<String> = []
			for outcome in outcomes {
				guard case .checked(_, let scenario, _) = outcome else { continue } // The check above let none through.
				installations.formUnion(scenario.installations.keys)
				print("▶︎ \(scenario.name)")
				let report = await ScenarioRunner(launcher: SimulatorLauncher()).run(scenario)
				for step in report.steps + report.teardown {
					let mark = step.passed ? "✓" : (step.bestEffort ? "⚠︎" : "✗")
					print("  \(mark) \(step.location)\(step.route.map { " → \($0)" } ?? "")")
				}
				// Never silent: a best-effort cleanup that did not run is printed on a green run too.
				report.warnings.forEach { print("   warning: \($0)") }
				if report.passed {
					print("✅ \(scenario.name) (\(String(format: "%.1f", report.durationSeconds)) s)")
				} else {
					failed.append(scenario.name)
					print("❌ \(scenario.name)")
					// Every line: a setup failure such as the route check's lists one step per line.
					HeadlessReportText.indented(report.failures, by: "   ").forEach { print($0) }
				}
			}
			for installation in installations {
				try? HeadlessSimulator(installation: installation).shutdown() // Best effort: frees the Simulator after the run.
			}
			if failed.isEmpty == false {
				print("\(failed.count) of \(paths.count) scenario(s) failed: \(failed.joined(separator: ", "))")
				throw ExitCode.failure
			}
			print("All \(paths.count) scenario(s) passed.")
		}

		/// `✓ <scenario>`, or `✗ <scenario>` and each failure on its own indented line.
		private static func printLint(_ outcome: HeadlessRouteLint.Outcome) {
			switch outcome {
			case .checked(_, let scenario, let failures):
				print("\(failures.isEmpty ? "✓" : "✗") \(scenario.name)")
				HeadlessReportText.indented(failures, by: "   ").forEach { print($0) }
			case .unreadable(let file, let error):
				print("✗ \(file.lastPathComponent)")
				HeadlessReportText.indented([error], by: "   ").forEach { print($0) }
			}
		}
	}
}

extension HeadlessExecFormat: ExpressibleByArgument {}

/// Launches scenario installations on their own simulators: fresh (erased) for a run's first
/// launch, with their data for a relaunch.
struct SimulatorLauncher: InstallationLauncher {

	func launch(installation: String, options: JSONValue, relaunch: Bool) async throws -> any HeadlessDriving {
		let simulator = try HeadlessSimulator(installation: installation)
		// A relaunch is a user reopening the app: no reinstall. Reinstalling moves the app's data
		// container, and preference writes the system had not flushed yet are lost with the move.
		let client = try await simulator.launch(options: options, fresh: relaunch == false, install: relaunch == false)
		try await client.connect()
		return client
	}

	func terminate(installation: String) async throws {
		try HeadlessSimulator(installation: installation).terminate()
	}
}

/// The repository's build of the headless app.
enum HeadlessWorkspace {

	static var root: URL {
		URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
	}

	/// Its own DerivedData: the headless compile condition would otherwise rebuild the app module
	/// that `unittest.sh` and the UI tests reuse from `.deriveddata`.
	static var derivedData: URL {
		root.appendingPathComponent(".deriveddata-headless")
	}

	static var app: URL {
		derivedData.appendingPathComponent("Build/Products/Debug-iphonesimulator/ML Browser.app")
	}

	static func build() throws {
		guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/MLBrowser.xcworkspace").path) else {
			throw ValidationError("run from the repository root (scripts/headless.sh does)")
		}
		let status = try runShellCommand("xcodebuild", arguments: [
			"build",
			"-workspace", "ios/MLBrowser.xcworkspace",
			"-scheme", "MLBrowser",
			"-configuration", "Debug",
			"-destination", "generic/platform=iOS Simulator",
			"-derivedDataPath", derivedData.path,
			"-skipPackagePluginValidation",
			"-skipMacroValidation",
			"-quiet",
			"AIA_APP_INTERFACE=headless",
			// No crash reporting from automation (AIA-0975): Sentry's "Github Alert" rule turns the first
			// error or fatal event of any environment into a GitHub issue, and scenario runs provoke
			// failures on purpose. The app disables Sentry when the DSN is empty. Remove this line once
			// that rule ignores the development environment.
			"SENTRY_DSN="
		])
		guard status == 0 else { throw ExitCode(status) }
	}

	static func defaultScenarios() throws -> [URL] {
		let directory = root.appendingPathComponent("ios/HeadlessScenarios")
		return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}
}

/// One installation's simulator, found — or created — by its `aia-headless-` name only.
struct HeadlessSimulator {

	let deviceName: String

	init(installation: String) throws {
		deviceName = try HeadlessDevice.deviceName(for: installation)
	}

	/// Launches the headless build — erasing the device first when `fresh`, installing the current
	/// build when `install` — and returns a connected client for the new endpoint.
	func launch(options: JSONValue, fresh: Bool, install: Bool) async throws -> HeadlessClient {
		guard FileManager.default.fileExists(atPath: HeadlessWorkspace.app.path) else {
			throw ValidationError("no headless build at \(HeadlessWorkspace.app.path); run `scripts/headless.sh build` first")
		}
		let launch = try HeadlessLaunchArguments.make(from: options, repositoryRoot: HeadlessWorkspace.root)
		let udid = try ensureDevice()
		if fresh {
			try? simctl(["shutdown", udid]) // Already shut down is fine.
			try simctl(["erase", udid])
		}
		try boot(udid)
		if fresh {
			// The free-access anchor lives in the Keychain, which survives app deletion by design.
			// `erase` already clears it on the iOS 27.0 simulator (AIA-0976 measured it); the reset
			// keeps a fresh install fresh on a runtime that might not.
			try await settling("keychain reset") {
				try simctl(["keychain", udid, "reset"])
			}
		}
		if install {
			try await settling("install") {
				try simctl(["install", udid, HeadlessWorkspace.app.path])
			}
		}
		// On every launch, relaunches included: a relaunch re-sends the same options, and the app is
		// told the names again, so the files must match the repository's current copies.
		try await stage(launch.stagedImages, udid: udid)
		let pid = try await launchApp(udid: udid, arguments: launch.arguments)
		let (client, hello) = try await connectWhenListening(udid: udid, pid: pid)
		// The launcher's lock on production data; the build and the app hold the other two.
		guard hello.metadata["backendEnvironment"] == "development" else {
			await client.close()
			try terminate()
			throw ValidationError("the headless app reports backend \(hello.metadata["backendEnvironment"]?.jsonString ?? "none"); refusing to drive anything but development")
		}
		// `headless.sh build` leaves Sentry off (see `HeadlessWorkspace.build`); a build made any other
		// way, or before that, would send the failures scenarios provoke to Sentry and on to GitHub.
		guard hello.metadata["crashReporting"] == false else {
			await client.close()
			try terminate()
			throw ValidationError("the headless app reports crashReporting \(hello.metadata["crashReporting"]?.jsonString ?? "unknown"); rebuild with `scripts/headless.sh build`")
		}
		return client
	}

	/// `simctl launch`, retried while a freshly erased device is still settling: its first launch
	/// often fails with `NSPOSIXErrorDomain` 3 (`SimulatorSettling`).
	/// - Returns: the launched process id, when `simctl` reports it.
	private func launchApp(udid: String, arguments: [String]) async throws -> Int32? {
		try await settling("launch") {
			// A stale file — from a previous run, or from an attempt that reported failure but started
			// the app anyway before the next attempt replaced it — must not be read as this launch's.
			removeEndpointFile(udid: udid)
			let output = try simctl(["launch", "--terminate-running-process", udid, HeadlessDevice.bundleIdentifier] + arguments)
			// "com.aiarcheology.ios: 12345"
			let text = (String(bytes: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			return text.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
		}
	}

	/// A `simctl` step that may fail while a freshly erased device settles — `install` fails with
	/// `IXErrorDomain` 2 ("Failed to create promise") — retried a bounded number of times, each
	/// failure reported.
	private func settling<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
		try await SimulatorSettling.retrying(attempts: 5, delay: .seconds(2), onRetry: { attempt, error in
			print("  \(step) attempt \(attempt) on \(deviceName) failed; retrying: \(error)")
		}, body)
	}

	/// Copies each image into the data container's `HeadlessDevice.stagedImagesPath`, replacing a
	/// file of the same name. The container lookup is retried like `install`: right after installing
	/// on a freshly erased device it can fail before the app's container exists.
	private func stage(_ images: [StagedImage], udid: String) async throws {
		guard images.isEmpty == false else { return }
		let container = try await settling("get_app_container") { try dataContainer(udid: udid) }
		let directory = try HeadlessDevice.stagingDirectory(in: container)
		for image in images {
			let destination = directory.appendingPathComponent(image.name)
			do {
				try FileManager.default.removeItem(at: destination)
			} catch let error as CocoaError where error.code == .fileNoSuchFile {
				// Nothing staged under this name yet.
			}
			try FileManager.default.copyItem(at: image.source, to: destination)
			print("  staged \(image.name)")
		}
	}

	func readEndpoint() throws -> HeadlessEndpoint {
		guard let udid = try existingDevice() else {
			throw ValidationError("\(deviceName) does not exist; run `scripts/headless.sh up` first")
		}
		let file = try endpointFile(udid: udid)
		guard FileManager.default.fileExists(atPath: file.path) else {
			throw ValidationError("the app on \(deviceName) is not running")
		}
		return try HeadlessEndpoint.read(from: file)
	}

	func terminate() throws {
		guard let udid = try existingDevice() else { return }
		try? simctl(["terminate", udid, HeadlessDevice.bundleIdentifier]) // Not running is fine.
	}

	func shutdown() throws {
		guard let udid = try existingDevice() else { return }
		try? simctl(["shutdown", udid]) // Already shut down is fine.
	}

	/// Erases the device and resets its Keychain, as a scenario's fresh launch does, so `up` after
	/// `reset` meets a fresh install too. The device is left shut down.
	func erase() async throws {
		guard let udid = try existingDevice() else { return }
		try? simctl(["shutdown", udid]) // Already shut down is fine.
		try simctl(["erase", udid])
		try boot(udid)
		try await settling("keychain reset") {
			try simctl(["keychain", udid, "reset"])
		}
		try simctl(["shutdown", udid])
	}

	// MARK: - Devices

	private struct DeviceList: Decodable {
		struct Device: Decodable {
			let name: String
			let udid: String
			let state: String
			let isAvailable: Bool?
		}
		let devices: [String: [Device]]
	}

	private func existingDevice() throws -> String? {
		let list = try JSONDecoder().decode(DeviceList.self, from: simctlOutput(["list", "devices", "-j"]))
		var matches = list.devices.values.flatMap { $0 }.filter { $0.name == deviceName }
		// A device of ours left on a runtime that has since been removed cannot boot: delete it, and a
		// fresh one is created on a current runtime.
		for stale in matches where stale.isAvailable == false {
			try simctl(["delete", stale.udid])
			print("Deleted \(deviceName) (\(stale.udid)): its runtime is no longer available")
		}
		matches.removeAll { $0.isAvailable == false }
		guard matches.count <= 1 else {
			throw ValidationError("several simulators are named \(deviceName); delete the extras")
		}
		return matches.first?.udid
	}

	private func ensureDevice() throws -> String {
		precondition(HeadlessDevice.isToolDevice(named: deviceName), "only aia-headless- devices are ever touched")
		if let udid = try existingDevice() { return udid }
		let sdk = (String(bytes: try process("/usr/bin/xcrun", ["xcodebuild", "-version", "-sdk", "iphonesimulator", "SDKVersion"]), encoding: .utf8) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let choice = try HeadlessSimulatorChoice.choose(runtimesJSON: simctlOutput(["list", "runtimes", "-j"]), sdkVersion: sdk)
		let udid = (String(bytes: try simctlOutput(["create", deviceName, choice.deviceTypeIdentifier, choice.runtimeIdentifier]), encoding: .utf8) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		print("Created \(deviceName) (\(udid))")
		return udid
	}

	private func boot(_ udid: String) throws {
		try? simctl(["boot", udid]) // Already booted is fine; bootstatus below is the real check.
		try simctl(["bootstatus", udid, "-b"])
	}

	private func dataContainer(udid: String) throws -> URL {
		let container = (String(bytes: try simctlOutput(["get_app_container", udid, HeadlessDevice.bundleIdentifier, "data"]), encoding: .utf8) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		// An empty answer would resolve against the working directory, and staging writes there.
		guard container.hasPrefix("/") else {
			throw ValidationError("simctl reported no data container for \(HeadlessDevice.bundleIdentifier) on \(deviceName)")
		}
		return URL(fileURLWithPath: container, isDirectory: true)
	}

	private func endpointFile(udid: String) throws -> URL {
		try dataContainer(udid: udid).appendingPathComponent(HeadlessDevice.endpointPath)
	}

	private func removeEndpointFile(udid: String) {
		guard let file = try? endpointFile(udid: udid) else { return } // No container yet: nothing stale.
		try? FileManager.default.removeItem(at: file) // Absent is fine.
	}

	/// Waits for the launched app to publish its endpoint and accept the handshake.
	///
	/// A refused connection is not final while the deadline lasts: the file found may belong to a
	/// process the launch retry has since replaced, and the live one rewrites it once listening.
	private func connectWhenListening(udid: String, pid: Int32?) async throws -> (HeadlessClient, ServerHello) {
		let file = try endpointFile(udid: udid)
		let deadline = Date().addingTimeInterval(120)
		var lastError: Error?
		while Date() < deadline {
			// Simulator apps are host processes. One that has gone away will never listen: say so now
			// rather than after the deadline. A malformed launch option stops the app on purpose.
			if let pid, kill(pid, 0) != 0, errno == ESRCH {
				throw ValidationError("the app on \(deviceName) exited during launch; check its launch options (an unknown -headlessFlag key stops it) and the device log")
			}
			if FileManager.default.fileExists(atPath: file.path) {
				do {
					let client = HeadlessClient(endpoint: try HeadlessEndpoint.read(from: file))
					let hello = try await client.connect()
					return (client, hello)
				} catch let error as HeadlessTransportError where error.kind == .notRunning {
					lastError = error
				}
			}
			try await Task.sleep(for: .milliseconds(250))
		}
		throw ValidationError("the app on \(deviceName) did not accept a connection within 120 s (\(lastError.map { "\($0)" } ?? "no endpoint published")); is this the headless build?")
	}

	// MARK: - Processes

	@discardableResult
	private func simctl(_ arguments: [String]) throws -> Data {
		try simctlOutput(arguments)
	}

	private func simctlOutput(_ arguments: [String]) throws -> Data {
		try process("/usr/bin/xcrun", ["simctl"] + arguments)
	}

	/// Runs a tool and returns its standard output; a non-zero exit is an error carrying its stderr.
	private func process(_ executable: String, _ arguments: [String]) throws -> Data {
		let task = Process()
		task.executableURL = URL(fileURLWithPath: executable)
		task.arguments = arguments
		let output = Pipe()
		let errors = Pipe()
		task.standardOutput = output
		task.standardError = errors
		try task.run()
		// Both pipes drained at once: reading one to its end while the child fills the other's buffer
		// would deadlock on a chatty tool.
		let errorReader = PipeDrain(errors.fileHandleForReading)
		let data = output.fileHandleForReading.readDataToEndOfFile()
		let errorData = errorReader.wait()
		task.waitUntilExit()
		guard task.terminationStatus == 0 else {
			let message = (String(bytes: errorData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			throw ValidationError("\(([executable] + arguments).joined(separator: " ")) failed: \(message)")
		}
		return data
	}
}

/// Reads a pipe to its end on a background thread.
private final class PipeDrain: @unchecked Sendable {
	// @unchecked: `data` is written once by the reader before `done` is signalled, and read only after.
	private var data = Data()
	private let done = DispatchSemaphore(value: 0)

	init(_ handle: FileHandle) {
		DispatchQueue.global(qos: .utility).async {
			self.data = handle.readDataToEndOfFile()
			self.done.signal()
		}
	}

	func wait() -> Data {
		done.wait()
		return data
	}
}
