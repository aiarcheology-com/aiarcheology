//
//  HeadlessLaunchOptions.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Foundation
import HeadlessKit

/// Launch arguments only the headless build reads: the few things it cannot yet reach the way a
/// user would. Each is explicit per launch and echoed in the handshake — never a hidden default, so
/// a scenario can always see what it ran against.
///
/// Everything else is the real composition of a Debug build: Clerk's development instance, the
/// development findings backend, ConfigCat's Test environment, and real persistent storage.
struct HeadlessLaunchOptions: Equatable {

	/// `-mockSubscription subscribed|notSubscribed`, the same argument `MockSubscriptionProvider`
	/// already parses. Needed because `simctl launch` never applies the scheme's StoreKit
	/// configuration, so real StoreKit is always "not subscribed" in the Simulator.
	let mockSubscription: String?

	/// `-headlessFlag key=true|false`, repeatable: pins a feature flag over the live provider. A
	/// scenario pins every flag it depends on, because ConfigCat's Test environment can change
	/// under it.
	let flagOverrides: [FeatureFlagKey: Bool]

	/// The options this process was launched with.
	static let current = HeadlessLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

	/// Reads the options from `arguments`. A malformed option stops the launch: an automation run on
	/// a misread configuration would pass or fail for the wrong reason.
	init(arguments: [String]) {
		var mockSubscription: String?
		var flagOverrides: [FeatureFlagKey: Bool] = [:]
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
			default:
				index += 1
			}
		}
		self.mockSubscription = mockSubscription
		self.flagOverrides = flagOverrides
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
		var members: [String: JSONValue] = ["flags": .object(flags)]
		members["mockSubscription"] = mockSubscription.map(JSONValue.string)
		return .object(members)
	}
}
#endif
