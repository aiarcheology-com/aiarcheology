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
			let simulator = try HeadlessSimulator(installation: state)
			let client = try await simulator.launch(options: .object(options), fresh: false, install: true)
			let hello = try await client.connect()
			await client.close()
			print(JSONValue.object(hello.metadata).jsonString)
		}
	}

	struct Exec: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Send one command: help, state, actions, goto <route>, perform <action> [k=v…], wait <condition> [k=v…] [timeout=s]."
		)

		@Option(name: .long, help: "Installation name.")
		var state: String = "a"

		@Argument(parsing: .captureForPassthrough, help: "The command and its arguments.")
		var command: [String] = []

		func run() async throws {
			let parsed = try HeadlessCommandLine.parse(command)
			let simulator = try HeadlessSimulator(installation: state)
			let client = HeadlessClient(endpoint: try simulator.readEndpoint())
			let response = try await client.send(parsed)
			await client.close()
			print(response.document.jsonString)
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
			try HeadlessSimulator(installation: state).erase()
		}
	}

	struct Test: AsyncParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Run scenarios (default: every ios/HeadlessScenarios/*.json), each on fresh installations.")

		@Flag(name: .long, help: "Use the existing headless build instead of building first.")
		var noBuild = false

		@Argument(help: "Scenario files.")
		var files: [String] = []

		func run() async throws {
			if noBuild == false {
				try HeadlessWorkspace.build()
			}
			let paths = files.isEmpty ? try HeadlessWorkspace.defaultScenarios() : files.map { URL(fileURLWithPath: $0) }
			guard paths.isEmpty == false else {
				throw ValidationError("no scenarios found")
			}
			var failed: [String] = []
			var installations: Set<String> = []
			for path in paths {
				let scenario: Scenario
				do {
					scenario = try Scenario.load(contentsOf: path)
				} catch {
					// One unreadable file must not stop the others, or leave their simulators running.
					failed.append(path.lastPathComponent)
					print("❌ \(path.lastPathComponent): \(error)")
					continue
				}
				installations.formUnion(scenario.installations.keys)
				print("▶︎ \(scenario.name)")
				let report = await ScenarioRunner(launcher: SimulatorLauncher()).run(scenario)
				for step in report.steps + report.teardown {
					print("  \(step.passed ? "✓" : "✗") \(step.location)\(step.route.map { " → \($0)" } ?? "")")
				}
				if report.passed {
					print("✅ \(scenario.name) (\(String(format: "%.1f", report.durationSeconds)) s)")
				} else {
					failed.append(scenario.name)
					print("❌ \(scenario.name)")
					report.failures.forEach { print("   \($0)") }
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
	}
}

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
			"AIA_APP_INTERFACE=headless"
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
		let arguments = try HeadlessLaunchArguments.make(from: options)
		let udid = try ensureDevice()
		if fresh {
			try? simctl(["shutdown", udid]) // Already shut down is fine.
			try simctl(["erase", udid])
		}
		try boot(udid)
		if install {
			try simctl(["install", udid, HeadlessWorkspace.app.path])
		}
		let pid = try await launchApp(udid: udid, arguments: arguments)
		let (client, hello) = try await connectWhenListening(udid: udid, pid: pid)
		// The launcher's lock on production data; the build and the app hold the other two.
		guard hello.metadata["backendEnvironment"] == "development" else {
			await client.close()
			try terminate()
			throw ValidationError("the headless app reports backend \(hello.metadata["backendEnvironment"]?.jsonString ?? "none"); refusing to drive anything but development")
		}
		return client
	}

	/// `simctl launch`, retried while a freshly erased device is still settling.
	///
	/// On a device just erased, booted and given the app, the first launch often fails with
	/// `NSPOSIXErrorDomain` 3 even after `bootstatus -b` reports the device booted, and succeeds
	/// seconds later (seen on Xcode 27.2 beta). There is no finer readiness signal to wait on, so the
	/// launch itself is retried a bounded number of times, each failure reported.
	/// - Returns: the launched process id, when `simctl` reports it.
	private func launchApp(udid: String, arguments: [String]) async throws -> Int32? {
		let attempts = 5
		for attempt in 1...attempts {
			// A stale file — from a previous run, or from an attempt that reported failure but started
			// the app anyway before the next attempt replaced it — must not be read as this launch's.
			removeEndpointFile(udid: udid)
			do {
				let output = try simctl(["launch", "--terminate-running-process", udid, HeadlessDevice.bundleIdentifier] + arguments)
				// "com.aiarcheology.ios: 12345"
				let text = (String(bytes: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
				return text.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
			} catch where attempt < attempts {
				print("  launch attempt \(attempt) on \(deviceName) failed; retrying: \(error)")
				try await Task.sleep(for: .seconds(2))
			}
		}
		return nil
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

	func erase() throws {
		guard let udid = try existingDevice() else { return }
		try? simctl(["shutdown", udid]) // Already shut down is fine.
		try simctl(["erase", udid])
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

	private func endpointFile(udid: String) throws -> URL {
		let container = (String(bytes: try simctlOutput(["get_app_container", udid, HeadlessDevice.bundleIdentifier, "data"]), encoding: .utf8) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return URL(fileURLWithPath: container).appendingPathComponent(HeadlessDevice.endpointPath)
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
