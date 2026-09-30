//
//  Headless.swift
//  ProjectToolCore
//
//  AIA-0970: the testable half of `ProjectTool headless`.
//

import Foundation
import HeadlessKit
import HeadlessScenario

/// The Debug app's build that headless mode runs from (AIA-0991): `scripts/unittest.sh`'s build,
/// argument for argument, so the two share one product and neither recompiles or relinks the other's.
///
/// `unittestSharedArguments` restates `unittest.sh`'s `XCODEBUILD_ARGS` without its action,
/// destination and DerivedData; a ProjectTool test reads the script and fails when the two differ.
public enum HeadlessBuild {

	/// The arguments `unittest.sh` passes to `xcodebuild test` that `headless.sh build` passes too.
	public static let unittestSharedArguments = [
		"-workspace", "ios/MLBrowser.xcworkspace",
		"-scheme", "MLBrowser",
		"AIA_INCLUDE_TEST_FIXTURES=YES",
		"-testPlan", "MLBrowserUnitTests",
		"-skipPackagePluginValidation",
		"-skipMacroValidation"
	]

	/// `unittest.sh`'s DerivedData when `DERIVED_DATA_PATH` is unset or empty, relative to the
	/// repository root.
	public static let defaultDerivedData = ".deriveddata"

	/// The full `xcodebuild` invocation.
	///
	/// `build-for-testing`, the build half of `unittest.sh`'s `test`, not `build`: the test build links
	/// the root package's products into the app as frameworks it shares with the test bundle, a
	/// plain `build` links them statically, and each relinks the other's app (measured on AIA-0991).
	/// `-configuration Debug` is what the scheme's test action uses anyway; `-quiet` affects output
	/// only. The destination is named by id, as in `unittest.sh`, so one architecture is compiled.
	public static func xcodebuildArguments(destinationUDID: String, derivedData: String, packageCache: String?) -> [String] {
		var arguments = ["build-for-testing"] + unittestSharedArguments + [
			"-configuration", "Debug",
			"-destination", "platform=iOS Simulator,id=\(destinationUDID)",
			"-derivedDataPath", derivedData,
			"-quiet"
		]
		if let packageCache, packageCache.isEmpty == false {
			arguments += ["-clonedSourcePackagesDirPath", packageCache]
		}
		return arguments
	}

	/// The running `xcodebuild` processes that use `derivedData`, from `ps -axo command=` output.
	/// Two builds into one DerivedData fail or corrupt it, and an install during a build can copy a
	/// half-written app, so the tool refuses to build or install while one runs.
	public static func buildsUsing(derivedData: String, psOutput: String) -> [String] {
		psOutput.split(separator: "\n").map(String.init).filter { line in
			let tokens = line.split(separator: " ").map(String.init)
			guard let executable = tokens.first, executable == "xcodebuild" || executable.hasSuffix("/xcodebuild") else { return false }
			guard let flag = tokens.firstIndex(of: "-derivedDataPath"), tokens.index(after: flag) < tokens.endIndex else { return false }
			return URL(fileURLWithPath: tokens[tokens.index(after: flag)]).standardizedFileURL.path
				== URL(fileURLWithPath: derivedData).standardizedFileURL.path
		}
	}
}

/// The simulator devices the headless tooling may touch — only its own.
///
/// Agents share this machine's simulators. Every device the tool creates, boots, erases or shuts
/// down is named with `namePrefix`, and it resolves devices by that name alone: there is no way to
/// hand it someone else's device.
public enum HeadlessDevice {

	public static let namePrefix = "aia-headless-"
	/// The app's bundle identifier; headless mode shares it with the app.
	public static let bundleIdentifier = "com.aiarcheology.ios"
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
public struct HeadlessLaunchPlan: Equatable {
	/// The launch block's options, as the app's launch arguments.
	public let arguments: [String]
	public let stagedImages: [StagedImage]

	/// Everything `simctl launch` passes to the app: headless mode and the app-moves rule, as the
	/// kit's `HeadlessLaunch` writes them (AIA-1007), then the options. `appMoves` is a run option
	/// (AIA-0994), never a scenario's launch key, so a committed scenario cannot weaken the
	/// transition check; `oneHop`, the app's default, adds nothing.
	public func processArguments(appMoves: AppMoves = .oneHop) -> [String] {
		HeadlessLaunch(isRequested: true, appMoves: appMoves).arguments + arguments
	}
}

/// Turns a scenario installation's `launch` block into the app's launch arguments and the images to
/// stage.
///
/// ```json
/// { "mockSubscription": "subscribed", "flags": { "isPaymentsEnabled": true }, "freeAccessEndsIn": 90, "stage": ["ios/Fixtures/site.png"] }
/// ```
///
/// `freeAccessEndsIn` (whole seconds) gives a fresh install a free-access window that ends that long
/// after launch (AIA-0984); an install that already holds one keeps it.
///
/// Strict, like the scenario format: an unknown key, a non-boolean flag or an unusable image is an
/// error, not a silently ignored option.
public enum HeadlessLaunchArguments {

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	/// The seconds `freeAccessEndsIn` accepts: the app's `FreeAccessExpirySeed.allowedSeconds`, which
	/// traps on anything else, restated because the tool does not link the app.
	public static let freeAccessEndsInSeconds = 30...3600

	/// - Parameter repositoryRoot: what `stage` paths are relative to, and must stay inside.
	public static func make(from options: JSONValue, repositoryRoot: URL) throws -> HeadlessLaunchPlan {
		guard let members = options.objectValue else {
			throw Invalid(description: "launch options must be an object")
		}
		let unknown = Set(members.keys).subtracting(["mockSubscription", "flags", "freeAccessEndsIn", "stage"])
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
		if let endsIn = members["freeAccessEndsIn"] {
			guard let seconds = endsIn.intValue, freeAccessEndsInSeconds.contains(seconds) else {
				throw Invalid(description: "freeAccessEndsIn must be whole seconds within \(freeAccessEndsInSeconds), got \(endsIn.jsonString)")
			}
			arguments += ["-headlessFreeAccessEndsIn", String(seconds)]
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
		return HeadlessLaunchPlan(arguments: arguments, stagedImages: stagedImages)
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
			throw Invalid(description: "expected a command: help, state, actions, map, goto, perform, wait")
		}
		let rest = Array(words.dropFirst())
		switch verb {
		case "help", "state", "actions":
			guard rest.isEmpty else { throw Invalid(description: "'\(verb)' takes no arguments") }
			return verb == "help" ? .help : verb == "state" ? .state : .actions
		case "map":
			// `exec` passes everything after the command through verbatim, so `exec map --format dot`
			// arrives here with the option as a word.
			guard rest.isEmpty else {
				throw Invalid(description: "'map' takes no arguments; options go before the command: exec --format dot map")
			}
			return .map
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

	/// `command` with its `name=value` text converted to the types the app declares (AIA-0992).
	///
	/// The protocol takes native JSON types only, so the command line asks first: `perform` reads the
	/// current screen's `actions`, `wait` reads `help`'s conditions (the built-in `route` included).
	/// Text becomes the declared kind and is never guessed from its look: `title=2024` stays a string
	/// for a string parameter. A command without arguments needs no conversion and costs no extra
	/// request. An action or parameter the app does not declare is left as text, so the app's own
	/// answer (`unknownAction`, `invalidArgument`) says what is wrong.
	public static func typed(_ command: Command, via driver: any HeadlessDriving) async throws -> Command {
		switch command {
		case .perform(let action, let arguments) where arguments.isEmpty == false:
			let offered = try await driver.send(.actions).actions
			guard let spec = offered.first(where: { $0.name == action }) else { return command }
			return .perform(action: action, arguments: try typed(arguments, against: spec.parameters, subject: "'\(action)'"))
		case .wait(let condition, let arguments, let timeout) where arguments.isEmpty == false:
			let help = try await driver.send(.help)
			guard let spec = try conditions(in: help).first(where: { $0.name == condition }) else { return command }
			return .wait(
				condition: condition,
				arguments: try typed(arguments, against: spec.parameters, subject: "condition '\(condition)'"),
				timeout: timeout
			)
		case .help, .state, .actions, .map, .perform, .goto, .wait:
			return command
		}
	}

	/// The largest integer a JSON number (a `Double`) holds exactly: beyond it, `Int` → `Double`
	/// rounds, and the app would receive a different number than the one typed.
	static let largestExactInteger = 9_007_199_254_740_991

	/// Converts each textual argument `parameters` declares to its kind; others stay text.
	static func typed(
		_ arguments: [String: JSONValue],
		against parameters: [ParameterSpec],
		subject: String
	) throws -> [String: JSONValue] {
		var result = arguments
		for parameter in parameters {
			guard case .string(let text) = arguments[parameter.name] else { continue }
			result[parameter.name] = try convert(text, to: parameter.kind, name: parameter.name, subject: subject)
		}
		return result
	}

	private static func convert(_ text: String, to kind: ParameterSpec.Kind, name: String, subject: String) throws -> JSONValue {
		func invalid(_ expected: String) -> Invalid {
			Invalid(description: "\(subject): '\(name)' must be \(expected), got '\(text)'")
		}
		switch kind {
		case .string:
			return .string(text)
		case .integer:
			// A range, not `abs`: `abs(Int.min)` traps.
			guard let integer = Int(text), (-largestExactInteger...largestExactInteger).contains(integer) else {
				throw invalid("an integer within ±\(largestExactInteger)")
			}
			return .number(Double(integer))
		case .number:
			guard let number = Double(text), number.isFinite else { throw invalid("a finite number") }
			return .number(number)
		case .boolean:
			switch text.lowercased() {
			case "true": return .bool(true)
			case "false": return .bool(false)
			default: throw invalid("true or false")
			}
		}
	}

	/// `help`'s wait conditions. Unreadable ones are an error here: sending the text unconverted
	/// would make the app report a type error for a value the user typed correctly.
	private static func conditions(in help: Response) throws -> [WaitConditionSpec] {
		guard let value = help.result?.value(at: "/conditions") else {
			throw Invalid(description: "the app's help lists no wait conditions, so the arguments cannot be typed: \(help.error?.description ?? "no result")")
		}
		do {
			let data = try HeadlessCoding.makeEncoder().encode(value)
			return try HeadlessCoding.makeDecoder().decode([WaitConditionSpec].self, from: data)
		} catch {
			throw Invalid(description: "the app's wait conditions could not be read, so the arguments cannot be typed: \(error)")
		}
	}

	/// `name=value` words as text; ``typed(_:via:)`` converts them to the declared types.
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

/// How `exec` prints a response (AIA-0982).
public enum HeadlessExecFormat: String, CaseIterable, Sendable {
	/// The whole response document.
	case json
	/// The `map` result as a Graphviz digraph (`HeadlessMapDot`).
	case dot

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	/// Refuses a format that cannot print `command`'s response: `dot` renders only `map`.
	public func check(_ command: Command) throws {
		guard self == .dot else { return }
		guard command == .map else {
			throw Invalid(description: "--format dot renders only the map command: exec --format dot map")
		}
	}
}

/// Renders a `map` result as a Graphviz digraph (AIA-0982): one node per declared route and one edge
/// per declared transition, in declaration order, so the same map always renders the same text.
///
/// - The current route is filled.
/// - An edge is labelled with its action; one the app takes on its own is dashed and italic.
/// - Open edges (offered now, leading there) are green and bold; available ones (offered now, the
///   destination decided when the action runs) are blue.
/// - Undeclared live transitions are red, dashed and labelled undeclared.
///
/// Every edge's tooltip is its condition: the graph shows what is **possible**, not guaranteed.
public enum HeadlessMapDot {

	public struct Invalid: Error, CustomStringConvertible {
		public let description: String
	}

	public static func render(_ result: JSONValue) throws -> String {
		guard let members = result.objectValue, let routes = members["routes"]?.arrayValue else {
			throw Invalid(description: "not a map result: expected an object with 'routes'")
		}
		let current = members["current"]?.stringValue
		var lines = [
			"digraph \"navigation map\" {",
			"\tlabel=\(quote("Possible transitions, not guaranteed" + (current.map { "; current: \($0)" } ?? "")));",
			"\tlabelloc=t;",
			"\trankdir=LR;",
			"\tnode [shape=box, style=rounded, fontname=\"Helvetica\"];",
			"\tedge [fontname=\"Helvetica\", fontsize=10];"
		]
		var declared: Set<String> = []
		var edges: [String] = []
		for (index, entry) in routes.enumerated() {
			guard let route = entry.objectValue, let name = route["route"]?.stringValue else {
				throw Invalid(description: "not a map result: routes[\(index)] has no 'route'")
			}
			declared.insert(name)
			var node: [(String, String)] = [("tooltip", route["summary"]?.stringValue ?? "")]
			if name == current {
				node += [("style", "rounded,filled,bold"), ("fillcolor", "gold")]
			}
			lines.append("\t\(quote(name)) \(attributes(node));")
			for (position, transitionValue) in (route["transitions"]?.arrayValue ?? []).enumerated() {
				guard let transition = transitionValue.objectValue, let target = transition["to"]?.stringValue else {
					throw Invalid(description: "not a map result: routes[\(index)].transitions[\(position)] has no 'to'")
				}
				var edge: [(String, String)]
				if let action = transition["action"]?.stringValue {
					if transition["open"]?.boolValue == true {
						edge = [("label", "\(action) (open)"), ("color", "forestgreen"), ("fontcolor", "forestgreen"), ("penwidth", "2.5")]
					} else if transition["available"]?.boolValue == true {
						edge = [("label", "\(action) (available)"), ("color", "royalblue"), ("fontcolor", "royalblue"), ("penwidth", "2")]
					} else {
						edge = [("label", action)]
					}
				} else {
					edge = [("label", "on its own"), ("style", "dashed"), ("fontname", "Helvetica-Oblique")]
				}
				edge.append(("tooltip", transition["condition"]?.stringValue ?? ""))
				edges.append("\t\(quote(name)) -> \(quote(target)) \(attributes(edge));")
			}
		}
		for (index, entry) in (members["undeclared"]?.arrayValue ?? []).enumerated() {
			guard let transition = entry.objectValue,
				  let action = transition["action"]?.stringValue,
				  let target = transition["to"]?.stringValue,
				  let current else {
				throw Invalid(description: "not a map result: undeclared[\(index)] needs 'action', 'to' and a current route")
			}
			// A live target the map does not declare at all: drawn red rather than as a plain node.
			if declared.insert(target).inserted {
				lines.append("\t\(quote(target)) \(attributes([("color", "red"), ("fontcolor", "red"), ("tooltip", "not a declared route")]));")
			}
			edges.append("\t\(quote(current)) -> \(quote(target)) \(attributes([("label", "\(action) (undeclared)"), ("color", "red"), ("fontcolor", "red"), ("style", "dashed")]));")
		}
		return (lines + edges + ["}"]).joined(separator: "\n")
	}

	/// `[label="close", color="red"]`, in the given order.
	private static func attributes(_ pairs: [(String, String)]) -> String {
		"[" + pairs.map { "\($0.0)=\(quote($0.1))" }.joined(separator: ", ") + "]"
	}

	/// A DOT quoted string: backslashes and quotes escaped, line breaks as `\n`.
	static func quote(_ text: String) -> String {
		var quoted = "\""
		for character in text {
			switch character {
			case "\\": quoted += "\\\\"
			case "\"": quoted += "\\\""
			case "\n", "\r", "\r\n": quoted += "\\n"
			default: quoted.append(character)
			}
		}
		return quoted + "\""
	}
}

/// The static route check shared by `headless test --lint` and the check `headless test` runs
/// before it builds (AIA-0983): every route a scenario names, against the checked-in navigation map.
///
/// It is an early filter only. The running app's handshake is authoritative: the runner checks the
/// routes again after each launch, against what that build declares.
public struct HeadlessRouteLint {

	/// The checked-in copy of the app's declaration, relative to the repository root.
	public static let mapPath = "ios/HeadlessScenarios/Map/navigation-map.json"

	/// The map cannot be used. Never a skip: without it nothing would be checked.
	public struct MapUnavailable: Error, CustomStringConvertible {
		public let description: String
	}

	/// One scenario file's result.
	public enum Outcome: Equatable {
		/// The file loaded; `failures` is empty when every route it names is declared.
		case checked(file: URL, scenario: Scenario, failures: [String])
		/// The file does not load as a scenario.
		case unreadable(file: URL, error: String)

		public var passed: Bool {
			if case .checked(_, _, let failures) = self { return failures.isEmpty }
			return false
		}

		/// The scenario's name, or the file's when it does not load.
		public var name: String {
			switch self {
			case .checked(_, let scenario, _): scenario.name
			case .unreadable(let file, _): file.lastPathComponent
			}
		}

		/// Why it failed, one message per line: the route check's, or why the file does not load.
		public var failures: [String] {
			switch self {
			case .checked(_, _, let failures): failures
			case .unreadable(_, let error): [error]
			}
		}
	}

	public let map: NavigationMap

	public init(map: NavigationMap) {
		self.map = map
	}

	/// Loads `mapPath` under `repositoryRoot`. A directory that is not the repository root throws
	/// `HeadlessRepositoryRoot.NotTheRoot` first, so running from the wrong place says so rather than
	/// that the map is missing. A missing, unreadable, undecodable or empty map throws.
	public init(repositoryRoot: URL) throws {
		try HeadlessRepositoryRoot.require(repositoryRoot)
		let file = repositoryRoot.appendingPathComponent(Self.mapPath)
		let regenerate = "It is regenerated by the failing HeadlessNavigationMapTests equality test "
			+ "(test_theCheckedInMap_isTheDeclaration, in the unit test plan), which prints the new content."
		let decoded: NavigationMap
		do {
			decoded = try HeadlessCoding.makeDecoder().decode(NavigationMap.self, from: Data(contentsOf: file))
		} catch {
			throw MapUnavailable(description: "cannot read the navigation map \(Self.mapPath): \(error). \(regenerate)")
		}
		// An empty map declares no routes, and the check would then pass every scenario unchecked.
		guard decoded.isEmpty == false else {
			throw MapUnavailable(description: "the navigation map \(Self.mapPath) declares no routes. \(regenerate)")
		}
		self.init(map: decoded)
	}

	/// One line per route `scenario` names that the map does not declare.
	public func failures(in scenario: Scenario) -> [String] {
		RouteCheck.failures(in: scenario, known: map.routeNames)
	}

	/// Loads and checks each file, in order; a file that does not load is an outcome, not a throw.
	public func check(_ files: [URL]) -> [Outcome] {
		files.map { file in
			do {
				let scenario = try Scenario.load(contentsOf: file)
				return .checked(file: file, scenario: scenario, failures: failures(in: scenario))
			} catch {
				return .unreadable(file: file, error: "\(error)")
			}
		}
	}
}

/// What `headless test` runs after the static route check (AIA-0983). A scenario that does not load
/// or names an undeclared route is reported and counted as failed, and does not run; one such file
/// must not stop the others. Only when none remains is nothing built.
public struct HeadlessTestPlan: Equatable {

	/// The scenarios that passed the check, in the order given: built for and run.
	public let runnable: [Scenario]
	/// The outcomes that failed the check, in the order given: reported, never run.
	public let rejected: [HeadlessRouteLint.Outcome]

	public init(_ outcomes: [HeadlessRouteLint.Outcome]) {
		runnable = outcomes.compactMap { outcome in
			guard case .checked(_, let scenario, let failures) = outcome, failures.isEmpty else { return nil }
			return scenario
		}
		rejected = outcomes.filter { $0.passed == false }
	}
}

/// The check that the tool runs from the repository root, which every path it uses is relative to.
public enum HeadlessRepositoryRoot {

	/// What only the repository root contains.
	public static let marker = "ios/MLBrowser.xcworkspace"

	public struct NotTheRoot: Error, CustomStringConvertible {
		public let description = "run from the repository root (scripts/headless.sh does)"
	}

	public static func require(_ directory: URL) throws {
		guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) else {
			throw NotTheRoot()
		}
	}
}

/// How `headless test` prints report messages.
public enum HeadlessReportText {

	/// How `test` marks a step: `✓` passed, `–` skipped because its `unless` held (not a warning), `⚠︎`
	/// a best-effort failure (a warning), `✗` a failure. Skipped is decided first: a skipped step
	/// has no failures, so it would otherwise print as passed.
	public static func mark(for step: StepReport) -> String {
		if step.skipped { return "–" }
		if step.passed { return "✓" }
		return step.bestEffort ? "⚠︎" : "✗"
	}

	/// Every line of every message, indented: the first by `indent`, a message's continuation lines
	/// two spaces deeper, so a multi-line failure still reads as one.
	public static func indented(_ messages: [String], by indent: String) -> [String] {
		messages.flatMap { message in
			message.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
				(index == 0 ? indent : indent + "  ") + line
			}
		}
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
