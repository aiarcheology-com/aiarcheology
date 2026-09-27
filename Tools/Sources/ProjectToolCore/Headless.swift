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
	/// Where the launcher copies a launch's staged images, relative to the app's data container. The
	/// app is told only each file's name (`-headlessStagedImage <name>`), never a host path, and reads
	/// it from here: its own sandbox, reachable without any network download.
	public static let stagedImagesPath = "Library/Application Support/Headless/Staged"

	public struct StagingOutsideContainer: Error, CustomStringConvertible {
		public var description: String {
			"the staged-images directory resolves outside the app's data container; refusing to write there"
		}
	}

	/// Creates the staged-images directory in `container` and returns it, refusing one that a
	/// symlink (the directory or any ancestor inside the container) redirects elsewhere. The
	/// launcher replaces files there, so a redirect would let it overwrite a host file.
	public static func stagingDirectory(in container: URL) throws -> URL {
		// One level at a time, each checked before anything is created under it, so a redirected
		// ancestor is refused before the launcher writes a single directory outside the container.
		var expected = container.standardizedFileURL.resolvingSymlinksInPath().pathComponents
		var directory = container
		for component in stagedImagesPath.split(separator: "/").map(String.init) {
			directory = directory.appendingPathComponent(component, isDirectory: true)
			expected.append(component)
			if FileManager.default.fileExists(atPath: directory.path) == false {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
			}
			guard directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents == expected else {
				throw StagingOutsideContainer()
			}
		}
		return directory
	}

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

/// An image the launcher copies from the repository into the app's data container before a launch.
public struct StagedImage: Equatable {
	/// The file in the repository, symlinks resolved.
	public let source: URL
	/// The file's name in `HeadlessDevice.stagedImagesPath`, and the only thing the app is told.
	public let name: String
}

/// What one launch needs: the app's launch arguments and the images to stage before it starts.
public struct HeadlessLaunch: Equatable {
	public let arguments: [String]
	public let stagedImages: [StagedImage]
}

/// Turns a scenario installation's `launch` block into the app's launch arguments and the images to
/// stage.
///
/// ```json
/// { "mockSubscription": "subscribed", "flags": { "isPaymentsEnabled": true }, "stage": ["ios/Fixtures/site.png"] }
/// ```
///
/// Strict, like the scenario format: an unknown key, a non-boolean flag or an unusable image is an
/// error, not a silently ignored option.
public enum HeadlessLaunchArguments {

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	/// - Parameter repositoryRoot: what `stage` paths are relative to, and must stay inside.
	public static func make(from options: JSONValue, repositoryRoot: URL) throws -> HeadlessLaunch {
		guard let members = options.objectValue else {
			throw Invalid(description: "launch options must be an object")
		}
		let unknown = Set(members.keys).subtracting(["mockSubscription", "flags", "stage"])
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
		var stagedImages: [StagedImage] = []
		if let stage = members["stage"] {
			guard let entries = stage.arrayValue else {
				throw Invalid(description: "stage must be an array of repository-relative image paths")
			}
			// Case-insensitively: the host's default file system, where the copies land, would
			// otherwise let one silently replace the other.
			var names: Set<String> = []
			for entry in entries {
				guard let path = entry.stringValue else {
					throw Invalid(description: "stage entries must be strings, got \(entry.jsonString)")
				}
				let image = try stagedImage(path, repositoryRoot: repositoryRoot)
				guard names.insert(image.name.lowercased()).inserted else {
					throw Invalid(description: "stage lists more than one image named '\(image.name)'; the app sees names only")
				}
				stagedImages.append(image)
				arguments += ["-headlessStagedImage", image.name]
			}
		}
		return HeadlessLaunch(arguments: arguments, stagedImages: stagedImages)
	}

	/// Validates one `stage` entry: a relative path to an existing regular png/jpg/jpeg file inside
	/// the repository.
	///
	/// Containment compares path components of the root and the candidate, both standardized and
	/// symlink-resolved the same way — never a string prefix (`/repo-other` is not inside `/repo`),
	/// and never a lexical check alone, which a symlink inside the repository pointing out of it
	/// would pass. Existence is checked first: `resolvingSymlinksInPath` drops a `/private` prefix
	/// only for a path that exists, so a missing file would otherwise read as an escape.
	static func stagedImage(_ entry: String, repositoryRoot: URL) throws -> StagedImage {
		guard entry.isEmpty == false else {
			throw Invalid(description: "stage entries must be non-empty paths")
		}
		guard entry.hasPrefix("/") == false else {
			throw Invalid(description: "stage entry '\(entry)' must be relative to the repository root")
		}
		let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
		let candidate = repositoryRoot.appendingPathComponent(entry).standardizedFileURL.resolvingSymlinksInPath()
		guard FileManager.default.fileExists(atPath: candidate.path) else {
			throw Invalid(description: "stage entry '\(entry)' does not exist")
		}
		guard candidate.pathComponents.starts(with: root.pathComponents),
			  candidate.pathComponents.count > root.pathComponents.count else {
			throw Invalid(description: "stage entry '\(entry)' resolves outside the repository")
		}
		let isRegularFile = (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false // Unreadable is not a usable file either.
		guard isRegularFile else {
			throw Invalid(description: "stage entry '\(entry)' is not a regular file")
		}
		let name = URL(fileURLWithPath: entry).lastPathComponent
		// The name travels as a launch-argument value; a leading '-' would read as another option.
		guard name.hasPrefix("-") == false else {
			throw Invalid(description: "stage entry '\(entry)' has a name starting with '-'")
		}
		// Both the name the app sees and the file actually copied: a link named `.png` may point at
		// anything.
		let imageExtensions = ["png", "jpg", "jpeg"]
		guard imageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()),
			  imageExtensions.contains(candidate.pathExtension.lowercased()) else {
			throw Invalid(description: "stage entry '\(entry)' must be a .png, .jpg or .jpeg image")
		}
		return StagedImage(source: candidate, name: name)
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

/// A `simctl` step retried a bounded number of times while a freshly erased device settles.
///
/// On a device just erased and booted, `simctl install` and `simctl launch` sometimes fail for a
/// few seconds after `bootstatus -b` reports the device booted, and then succeed unchanged (seen on
/// Xcode 27.2 beta). There is no finer readiness signal to wait on, so the step itself is retried.
public enum SimulatorSettling {

	/// Runs `step` up to `attempts` times, `delay` apart, reporting each failure before a retry; the
	/// last attempt's error is thrown.
	public static func retrying<T>(
		attempts: Int,
		delay: Duration,
		onRetry: (_ attempt: Int, _ error: any Error) -> Void,
		_ step: () async throws -> T
	) async throws -> T {
		precondition(attempts >= 1, "at least one attempt")
		for attempt in 1..<attempts {
			do {
				return try await step()
			} catch {
				onRetry(attempt, error)
				try await Task.sleep(for: delay)
			}
		}
		return try await step()
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
