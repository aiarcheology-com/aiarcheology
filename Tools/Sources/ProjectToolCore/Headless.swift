//
//  Headless.swift
//  ProjectToolCore
//
//  AIA-0970: the testable half of `ProjectTool headless`.
//

import Foundation
import HeadlessKit

/// The simulator devices the headless tooling may touch — only its own.
///
/// Agents share this machine's simulators. Every device the tool creates, boots, erases or shuts
/// down is named with `namePrefix`, and it resolves devices by that name alone: there is no way to
/// hand it someone else's device.
public enum HeadlessDevice {

	public static let namePrefix = "aia-headless-"
	/// The app's bundle identifier; the headless build shares it with the app.
	public static let bundleIdentifier = "com.aiarcheology.ios"
	/// Where the app publishes its endpoint, relative to its data container.
	public static let endpointPath = "Library/Application Support/Headless/endpoint.json"

	public struct InvalidName: Error, CustomStringConvertible {
		public let name: String
		public var description: String {
			"'\(name)' is not a usable installation name: use 1-40 lowercase letters, digits or '-', starting with a letter or digit"
		}
	}

	/// The device name for an installation, e.g. `a` → `aia-headless-a`.
	public static func deviceName(for installation: String) throws -> String {
		let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
		guard (1...40).contains(installation.count),
			  installation.allSatisfy(allowed.contains),
			  installation.first != "-" else {
			throw InvalidName(name: installation)
		}
		return namePrefix + installation
	}

	public static func isToolDevice(named name: String) -> Bool {
		name.hasPrefix(namePrefix) && name.count > namePrefix.count
	}
}

/// Turns a scenario installation's `launch` block into the app's launch arguments.
///
/// ```json
/// { "mockSubscription": "subscribed", "flags": { "isPaymentsEnabled": true } }
/// ```
///
/// Strict, like the scenario format: an unknown key or a non-boolean flag is an error, not a
/// silently ignored option.
public enum HeadlessLaunchArguments {

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	public static func make(from options: JSONValue) throws -> [String] {
		guard let members = options.objectValue else {
			throw Invalid(description: "launch options must be an object")
		}
		let unknown = Set(members.keys).subtracting(["mockSubscription", "flags"])
		guard unknown.isEmpty else {
			throw Invalid(description: "unknown launch option(s): \(unknown.sorted().joined(separator: ", "))")
		}
		var arguments: [String] = []
		if let mock = members["mockSubscription"] {
			guard let outcome = mock.stringValue, ["subscribed", "notSubscribed"].contains(outcome) else {
				throw Invalid(description: "mockSubscription must be \"subscribed\" or \"notSubscribed\"")
			}
			arguments += ["-mockSubscription", outcome]
		}
		if let flags = members["flags"] {
			guard let pins = flags.objectValue else {
				throw Invalid(description: "flags must be an object of key: true|false")
			}
			for key in pins.keys.sorted() {
				guard let value = pins[key]?.boolValue else {
					throw Invalid(description: "flag '\(key)' must be true or false")
				}
				arguments += ["-headlessFlag", "\(key)=\(value)"]
			}
		}
		return arguments
	}
}

/// Reads `exec` arguments as a command: `state`, `goto drawer`, `perform enable id=…`,
/// `wait model-loaded id=… timeout=60`.
public enum HeadlessCommandLine {

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	public static func parse(_ words: [String]) throws -> Command {
		guard let verb = words.first else {
			throw Invalid(description: "expected a command: help, state, actions, goto, perform, wait")
		}
		let rest = Array(words.dropFirst())
		switch verb {
		case "help", "state", "actions":
			guard rest.isEmpty else { throw Invalid(description: "'\(verb)' takes no arguments") }
			return verb == "help" ? .help : verb == "state" ? .state : .actions
		case "goto":
			guard rest.count == 1 else { throw Invalid(description: "usage: goto <route>") }
			return .goto(Route(rest[0]))
		case "perform":
			guard let action = rest.first else { throw Invalid(description: "usage: perform <action> [name=value …]") }
			return .perform(action: action, arguments: try pairs(Array(rest.dropFirst())))
		case "wait":
			guard let condition = rest.first else { throw Invalid(description: "usage: wait <condition> [name=value …] [timeout=<seconds>]") }
			var arguments = try pairs(Array(rest.dropFirst()))
			var timeout: Double?
			if let raw = arguments.removeValue(forKey: "timeout") {
				guard let text = raw.stringValue, let seconds = Double(text) else {
					throw Invalid(description: "timeout must be a number of seconds")
				}
				timeout = seconds
			}
			return .wait(condition: condition, arguments: arguments, timeout: timeout)
		default:
			throw Invalid(description: "unknown command '\(verb)'")
		}
	}

	/// `name=value` words as string arguments; the app converts them to the declared types.
	private static func pairs(_ words: [String]) throws -> [String: JSONValue] {
		var result: [String: JSONValue] = [:]
		for word in words {
			let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
			guard parts.count == 2, parts[0].isEmpty == false else {
				throw Invalid(description: "expected name=value, got '\(word)'")
			}
			result[parts[0]] = .string(parts[1])
		}
		return result
	}
}

/// Picks the runtime and device type for a new headless device from `simctl list runtimes -j`.
public enum HeadlessSimulatorChoice {

	public struct Choice: Equatable {
		public let runtimeIdentifier: String
		public let deviceTypeIdentifier: String
	}

	public struct Unavailable: Error, CustomStringConvertible {
		public let description: String
	}

	private struct RuntimeList: Decodable {
		let runtimes: [Runtime]
	}

	private struct Runtime: Decodable {
		let identifier: String
		let version: String
		let platform: String?
		let isAvailable: Bool
		let supportedDeviceTypes: [DeviceType]?
	}

	private struct DeviceType: Decodable {
		let identifier: String
		let productFamily: String?
		let minRuntimeVersion: Int?
	}

	/// The newest available iOS runtime the active SDK can drive, and its newest iPhone — "newest"
	/// by `minRuntimeVersion`, because neither list is sorted by recency.
	public static func choose(runtimesJSON: Data, sdkVersion: String) throws -> Choice {
		let list = try JSONDecoder().decode(RuntimeList.self, from: runtimesJSON)
		let cap = version(sdkVersion)
		let candidates = list.runtimes
			.filter { runtime in
				let runtimeVersion = version(runtime.version)
				let isDrivable = runtimeVersion == cap || runtimeVersion.lexicographicallyPrecedes(cap)
				return runtime.isAvailable && (runtime.platform ?? "iOS") == "iOS" && isDrivable
			}
			.sorted { version($1.version).lexicographicallyPrecedes(version($0.version)) }
		for runtime in candidates {
			let phones = (runtime.supportedDeviceTypes ?? []).filter { $0.productFamily == "iPhone" }
			if let newest = phones.max(by: { ($0.minRuntimeVersion ?? 0, $0.identifier) < ($1.minRuntimeVersion ?? 0, $1.identifier) }) {
				return Choice(runtimeIdentifier: runtime.identifier, deviceTypeIdentifier: newest.identifier)
			}
		}
		throw Unavailable(description: "no available iOS runtime at or below SDK \(sdkVersion) with an iPhone device type")
	}

	/// `"27.0"` → `[27, 0]`, compared lexicographically.
	static func version(_ text: String) -> [Int] {
		text.split(separator: ".").compactMap { Int($0) }
	}
}
