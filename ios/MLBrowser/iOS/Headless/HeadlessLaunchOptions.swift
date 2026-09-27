//
//  HeadlessLaunchOptions.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Foundation
import HeadlessKit

/// Launch arguments only headless mode reads: the few things it cannot yet reach the way a
/// user would. Each is explicit per launch and echoed in the handshake — never a hidden default, so
/// a scenario can always see what it ran against.
///
/// Everything else is the real composition of a Debug build: Clerk's development instance, the
/// development findings backend, ConfigCat's Test environment, and real persistent storage.
struct HeadlessLaunchOptions: Equatable {

	/// `-mockSubscription subscribed|notSubscribed`, the same argument `MockSubscriptionProvider`
	/// already parses. For manual launches only: real StoreKit is the default and reads as not
	/// subscribed, and a subscribed install would otherwise need a real sandbox purchase. No
	/// committed scenario uses it (a ProjectTool test enforces that; AIA-0976).
	let mockSubscription: String?

	/// `-headlessFlag key=true|false`, repeatable: pins a feature flag over the live provider. A
	/// scenario pins every flag it depends on, because ConfigCat's Test environment can change
	/// under it.
	let flagOverrides: [FeatureFlagKey: Bool]

	/// `-headlessStagedImage <name>`, repeatable, in launch order: images the launching tool copied
	/// into `Library/Application Support/Headless/Staged/` before the launch. `detect-image` accepts
	/// only these names, so a client cannot point detection at any other file in the container.
	let stagedImages: [String]

	/// `-headlessFreeAccessEndsIn <seconds>`: on a fresh install, a free-access window that ends this
	/// many seconds after launch (`FreeAccessExpirySeed.allowedSeconds`), so a scenario can watch the
	/// paywall arrive mid-session through the app's own expiry path. Seeded by the headless entry
	/// before `AppState` exists; an install that already holds an anchor keeps it.
	let freeAccessEndsIn: Int?

	/// The options this process was launched with. Read only in headless mode (AIA-0991): parsing
	/// traps on a malformed option, and a UI launch must not stop on a stale one.
	static let current = HeadlessLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

	/// Reads the options from `arguments`. A malformed option stops the launch: an automation run on
	/// a misread configuration would pass or fail for the wrong reason.
	init(arguments: [String]) {
		var mockSubscription: String?
		var flagOverrides: [FeatureFlagKey: Bool] = [:]
		var stagedImages: [String] = []
		var freeAccessEndsIn: Int?
		var index = arguments.startIndex
		while index < arguments.endIndex {
			let argument = arguments[index]
			let value = arguments.index(after: index) < arguments.endIndex ? arguments[arguments.index(after: index)] : nil
			switch argument {
			case "-mockSubscription":
				guard let value, MockSubscriptionProvider.Outcome(rawValue: value) != nil else {
					fatalError("-mockSubscription needs subscribed or notSubscribed, got \(value ?? "nothing")")
				}
				mockSubscription = value
				index += 2
			case "-headlessFlag":
				guard let value else { fatalError("-headlessFlag needs key=true|false") }
				let (key, flag) = Self.parseFlag(value)
				flagOverrides[key] = flag
				index += 2
			case "-headlessStagedImage":
				guard let value, Self.isStagedImageName(value) else {
					fatalError("-headlessStagedImage needs a bare file name (no '/', not '.' or '..', no leading '-'), got \(value ?? "nothing")")
				}
				stagedImages.append(value)
				index += 2
			case "-headlessFreeAccessEndsIn":
				guard let seconds = value.flatMap(Self.freeAccessEndsIn) else {
					fatalError("-headlessFreeAccessEndsIn needs whole seconds within \(FreeAccessExpirySeed.allowedSeconds), got \(value ?? "nothing")")
				}
				freeAccessEndsIn = seconds
				index += 2
			default:
				index += 1
			}
		}
		self.mockSubscription = mockSubscription
		self.flagOverrides = flagOverrides
		self.stagedImages = stagedImages
		self.freeAccessEndsIn = freeAccessEndsIn
	}

	/// `text` as seconds a launch may ask for, or `nil`. Not private so the rule can be tested
	/// without the `fatalError` a launch hits.
	static func freeAccessEndsIn(_ text: String) -> Int? {
		guard let seconds = Int(text), FreeAccessExpirySeed.allowedSeconds.contains(seconds) else { return nil }
		return seconds
	}

	/// A bare file name inside the staging directory: never a path out of it, and never something
	/// that reads as the next launch option (a missing value would otherwise swallow it). Not
	/// private so the rule can be tested without the `fatalError` a launch hits.
	static func isStagedImageName(_ name: String) -> Bool {
		name.isEmpty == false && name.contains("/") == false && name != "." && name != ".." && name.hasPrefix("-") == false
	}

	private static func parseFlag(_ text: String) -> (FeatureFlagKey, Bool) {
		let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
		guard parts.count == 2, let key = FeatureFlagKey(rawValue: parts[0]) else {
			fatalError("-headlessFlag \(text): expected key=true|false with a known flag key")
		}
		switch parts[1] {
		case "true": return (key, true)
		case "false": return (key, false)
		default: fatalError("-headlessFlag \(text): the value must be true or false")
		}
	}

	/// The options as the handshake and `context` report them.
	var json: JSONValue {
		var flags: [String: JSONValue] = [:]
		for (key, value) in flagOverrides {
			flags[key.rawValue] = .bool(value)
		}
		var members: [String: JSONValue] = [
			"flags": .object(flags),
			"stagedImages": .array(stagedImages.map(JSONValue.string))
		]
		members["mockSubscription"] = mockSubscription.map(JSONValue.string)
		members["freeAccessEndsIn"] = freeAccessEndsIn.map { .number(Double($0)) }
		return .object(members)
	}
}
#endif
