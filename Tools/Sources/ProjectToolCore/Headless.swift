//
//  Headless.swift
//  ProjectToolCore
//
//  AIA-0970: the testable half of `ProjectTool headless`. Since AIA-1008 the commands are the
//  kit's (`HeadlessTool`); `MLBrowserHeadless` is what they need to know about ML Browser.
//

import Foundation
import HeadlessKit
import HeadlessSimulatorLauncher

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

/// ML Browser's headless devices and container layout.
///
/// Agents share this machine's simulators. The kit's tooling creates, boots, erases or shuts down
/// only devices named with `namePrefix`, and resolves devices by that name alone.
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
}

/// An image the launcher copies from the repository into the app's data container before a launch.
public struct StagedImage: Equatable, Sendable {
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

/// What the kit's `headless` commands need to know about ML Browser (AIA-1008): its Debug build,
/// how to build it, its launch options and the handshake it must give.
///
/// The build is `scripts/unittest.sh`'s, in the same DerivedData, so one product serves the unit
/// tests, the UI tests and headless mode, and a build right after `unittest.sh` compiles no Swift.
public struct MLBrowserHeadless: HeadlessProject {

	/// The checked-in navigation map, relative to the repository root.
	public static let navigationMapPath = "ios/HeadlessScenarios/Map/navigation-map.json"

	/// The working directory: the repository root, which every path is relative to.
	public let root: URL
	let environment: [String: String]
	/// Runs a tool in the foreground, its output going straight to the terminal; returns its status.
	let runTool: @Sendable (_ command: String, _ arguments: [String]) throws -> Int32
	/// `ps -axo command=`'s output.
	let processList: @Sendable () throws -> String

	public init(
		root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
		environment: [String: String] = ProcessInfo.processInfo.environment,
		runTool: @escaping @Sendable (_ command: String, _ arguments: [String]) throws -> Int32,
		processList: @escaping @Sendable () throws -> String
	) {
		self.root = root
		self.environment = environment
		self.runTool = runTool
		self.processList = processList
	}

	/// A step of the build that failed; it has already printed why.
	public struct BuildFailure: Error, CustomStringConvertible {
		public let description: String
	}

	/// `unittest.sh`'s: `DERIVED_DATA_PATH` when set, else `.deriveddata`.
	public var derivedData: URL {
		if let path = environment["DERIVED_DATA_PATH"], path.isEmpty == false {
			return URL(fileURLWithPath: path)
		}
		return root.appendingPathComponent(HeadlessBuild.defaultDerivedData)
	}

	public var app: URL {
		derivedData.appendingPathComponent("Build/Products/Debug-iphonesimulator/ML Browser.app")
	}

	public var bundleIdentifier: String { HeadlessDevice.bundleIdentifier }

	public var devicePrefix: String { HeadlessDevice.namePrefix }

	public var invocation: String { "scripts/headless.sh" }

	public var scenariosDirectory: URL { root.appendingPathComponent("ios/HeadlessScenarios", isDirectory: true) }

	public var navigationMap: URL? { root.appendingPathComponent(Self.navigationMapPath) }

	public var upOptions: [HeadlessUpOption] {
		[
			HeadlessUpOption("mock-subscription", help: "subscribed or notSubscribed (StoreKit is inert under simctl).") { launch, value in
				launch["mockSubscription"] = .string(value)
			},
			HeadlessUpOption("flag", help: "Pin a feature flag, key=true|false", repeatable: true) { launch, value in
				let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
				guard parts.count == 2, let pin = Bool(parts[1]) else {
					throw HeadlessUsageError("--flag expects key=true|false, got '\(value)'")
				}
				var flags = launch["flags"]?.objectValue ?? [:]
				flags[parts[0]] = .bool(pin)
				launch["flags"] = .object(flags)
			},
			HeadlessUpOption("free-access-ends-in", help: "On a fresh install, end free access this many seconds (30...3600) after launch.") { launch, value in
				guard let seconds = Int(value) else {
					throw HeadlessUsageError("--free-access-ends-in expects whole seconds, got '\(value)'")
				}
				launch["freeAccessEndsIn"] = .number(Double(seconds))
			},
			// As a scenario's `stage`, so it gets the same validation and staging.
			HeadlessUpOption("image", help: "Stage a .png/.jpg/.jpeg from the repository, path relative to its root, in the app's container", repeatable: true) { launch, value in
				launch["stage"] = .array((launch["stage"]?.arrayValue ?? []) + [.string(value)])
			}
		]
	}

	public func validateWorkingDirectory() throws {
		try HeadlessRepositoryRoot.require(root)
	}

	/// `unittest.sh`'s build (`HeadlessBuild.xcodebuildArguments`) into its DerivedData and package
	/// cache. The destination is installation `a`'s simulator rather than the unit tests' iPhone; that
	/// changes only asset thinning, never a compile or a link.
	///
	/// No crash-reporting override: headless mode runs the no-op reporter whatever the build carries
	/// (`DependencyContainer`), and `accept` checks the handshake says so.
	public func build(destination: () async throws -> String) async throws {
		try HeadlessRepositoryRoot.require(root)
		try requireNoBuildInProgress()
		// The fixture the build embeds (`embed_apple_test_models.sh`) must be on disk first, as in
		// unittest.sh; without it the build fails.
		let fetch = "scripts/fetch_apple_test_models.sh"
		let fetched = try runTool(fetch, [])
		guard fetched == 0 else { throw BuildFailure(description: "\(fetch) failed with exit code \(fetched)") }
		let udid = try await destination()
		let status = try runTool("xcodebuild", HeadlessBuild.xcodebuildArguments(
			destinationUDID: udid,
			derivedData: derivedData.path,
			packageCache: environment["SPM_CACHE_PATH"]
		))
		guard status == 0 else { throw BuildFailure(description: "xcodebuild failed with exit code \(status)") }
	}

	public func willInstall() throws {
		try requireNoBuildInProgress()
		try requireDevelopmentProduct()
	}

	public func prepareLaunch(_ options: JSONValue) throws -> HeadlessLaunchPreparation {
		let plan = try HeadlessLaunchArguments.make(from: options, repositoryRoot: root)
		let images = plan.stagedImages
		guard images.isEmpty == false else { return HeadlessLaunchPreparation(arguments: plan.arguments) }
		return HeadlessLaunchPreparation(arguments: plan.arguments) { container in
			try Self.stage(images, in: container)
		}
	}

	public func accept(_ hello: ServerHello, appMoves: AppMoves) throws {
		if let refusal = Self.refusal(of: hello.metadata, appMoves: appMoves) {
			throw HeadlessUsageError(refusal)
		}
	}

	/// Why the launched app must not be driven, or nil. In order: the backend (the launcher's lock
	/// on production data; the build and the app hold the other two), the crash reporter (one that
	/// runs would send the failures scenarios provoke to Sentry and on to GitHub), and the run's
	/// transition rule (AIA-0994: a map audit that silently ran with the hop on would pass for the
	/// wrong reason).
	public static func refusal(of metadata: [String: JSONValue], appMoves: AppMoves) -> String? {
		guard metadata["backendEnvironment"] == "development" else {
			return "the headless app reports backend \(metadata["backendEnvironment"]?.jsonString ?? "none"); refusing to drive anything but development"
		}
		guard metadata["crashReporting"] == false else {
			return "the headless app reports crashReporting \(metadata["crashReporting"]?.jsonString ?? "unknown"); headless mode must run without a crash reporter, so refusing to drive it"
		}
		let reported = metadata["launchOptions"]?.value(at: "/appMoves")
		guard reported == .string(appMoves.rawValue) else {
			return "the headless app reports appMoves \(reported?.jsonString ?? "none"), not \(appMoves.rawValue); rebuild it (scripts/headless.sh build)"
		}
		return nil
	}

	/// Copies each image into the data container's `HeadlessDevice.stagedImagesPath`, replacing a
	/// file of the same name.
	static func stage(_ images: [StagedImage], in container: URL) throws {
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

	/// Refuses while another `xcodebuild` uses the shared DerivedData — `unittest.sh`, a UI test run,
	/// another `headless.sh build`: two builds into one DerivedData fail or corrupt it, and an install
	/// during a build can copy a half-written app.
	func requireNoBuildInProgress() throws {
		guard HeadlessBuild.buildsUsing(derivedData: derivedData.path, psOutput: try processList()).isEmpty else {
			throw HeadlessUsageError("another xcodebuild is using \(derivedData.path); wait for it to finish (headless mode shares unittest.sh's DerivedData)")
		}
	}

	/// Refuses a product that cannot run headless mode before installing it: only a build for the
	/// development backend has one. (An older product without the mode is caught at connect time.)
	func requireDevelopmentProduct() throws {
		let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
		let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
		let backend = info?["BackendEnvironment"] as? String
		guard backend == "development" else {
			throw HeadlessUsageError("the Debug build at \(app.path) is for the \(backend ?? "unknown") backend; headless mode exists only in a development build")
		}
	}
}
