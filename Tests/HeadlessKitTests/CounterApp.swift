//
//  CounterApp.swift
//  HeadlessKitTests
//
//  AIA-0970.
//

import Foundation
import HeadlessKit

/// A minimal adopter: a counter with a drawer. Small enough to reason about, but with every shape
/// the session must handle — transitions, typed parameters, async effects, failures, ambiguity.
@MainActor
final class CounterApp: HeadlessApplication {

	var count = 0
	var isDrawerOpen = false
	/// Transitions the app actually took, in order.
	var performed: [String] = []

	var metadata: [String: JSONValue] { ["app": "counter"] }

	func currentScreen() -> any HeadlessScreen {
		isDrawerOpen ? DrawerScreen(app: self) : HomeScreen(app: self)
	}

	func context() -> JSONValue {
		["count": .number(Double(count)), "drawerOpen": .bool(isDrawerOpen)]
	}

	func waitConditions() -> [WaitCondition] {
		[
			WaitCondition(
				"count-at-least",
				summary: "The count reached a value.",
				parameters: [ParameterSpec("value", .integer)]
			) { [unowned self] arguments in
				self.count >= (try arguments.integer("value"))
			}
		]
	}
}

struct TestFailure: Error, CustomStringConvertible {
	var description: String { "the fake action failed" }
}

@MainActor
struct HomeScreen: HeadlessScreen {

	let app: CounterApp

	var route: Route { "home" }

	func state() -> JSONValue {
		["count": .number(Double(app.count))]
	}

	func actions() -> [HeadlessAction] {
		[
			HeadlessAction("open-drawer", summary: "Open the drawer.", navigatesTo: "drawer") { [app] _ in
				app.performed.append("open-drawer")
				app.isDrawerOpen = true
				return nil
			},
			HeadlessAction(
				"increment",
				summary: "Add to the count.",
				parameters: [ParameterSpec("by", .integer, required: false)]
			) { [app] arguments in
				let step = arguments["by"] == nil ? 1 : try arguments.integer("by")
				app.count += step
				return ["count": .number(Double(app.count))]
			},
			// Completes its effect later, as a model load does.
			HeadlessAction("increment-later", summary: "Add one after a delay.") { [app] _ in
				Task { @MainActor in
					do {
						try await Task.sleep(for: .milliseconds(60))
					} catch {
						return // Cancelled with the test; nothing to add.
					}
					app.count += 1
				}
				return nil
			},
			// Awaits its own effect before returning, as the rule for handlers requires.
			HeadlessAction("increment-slowly", summary: "Add one, taking a while.") { [app] _ in
				try await Task.sleep(for: .milliseconds(60))
				app.count += 1
				return nil
			},
			// Declares a transition it never makes: the drift the session must refuse to hide.
			HeadlessAction("broken-transition", summary: "Claims to open About.", navigatesTo: "about") { _ in
				nil
			},
			HeadlessAction("reject", summary: "Fails with a coded error.") { _ in
				throw HeadlessError(.invalidArgument, "not today")
			},
			HeadlessAction("crash", summary: "Fails with an arbitrary error.") { _ in
				throw TestFailure()
			},
			HeadlessAction(
				"rename",
				summary: "Takes typed parameters.",
				parameters: [
					ParameterSpec("name", .string),
					ParameterSpec("loud", .boolean, required: false),
					ParameterSpec("weight", .number, required: false)
				]
			) { arguments in
				["name": .string(try arguments.string("name")), "arguments": .object(arguments.values)]
			}
		]
	}
}

@MainActor
struct DrawerScreen: HeadlessScreen {

	let app: CounterApp

	var route: Route { "drawer" }

	func actions() -> [HeadlessAction] {
		[
			HeadlessAction("close", summary: "Close the drawer.", navigatesTo: "home") { [app] _ in
				app.isDrawerOpen = false
				return nil
			},
			// Two ways to one place: `goto settings` must refuse to pick one.
			HeadlessAction("settings-from-header", summary: "", navigatesTo: "settings") { _ in nil },
			HeadlessAction("settings-from-footer", summary: "", navigatesTo: "settings") { _ in nil },
			HeadlessAction("profile", summary: "", parameters: [ParameterSpec("id", .string)], navigatesTo: "profile") { _ in nil }
		]
	}
}
