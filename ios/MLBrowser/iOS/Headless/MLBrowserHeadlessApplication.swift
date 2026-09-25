//
//  MLBrowserHeadlessApplication.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Foundation
import HeadlessKit

/// ML Browser as a headless client sees it: screens derived from the real `AppState`.
///
/// `#if DEBUG` rather than headless-only, so the ordinary Debug build — the unit-test host —
/// compiles and tests it. Only the headless entry point ever instantiates it.
///
/// This first version knows two routes: `launching` until `AppState` is ready, then `ready`. The
/// screens a user moves through after launch are added on top of it (AIA-0970 PR 3).
@MainActor
final class MLBrowserHeadlessApplication: HeadlessApplication {

	private let appState: AppState
	private let launchOptions: JSONValue

	init(appState: AppState, launchOptions: JSONValue) {
		self.appState = appState
		self.launchOptions = launchOptions
	}

	var metadata: [String: JSONValue] {
		let info = Bundle.main.infoDictionary ?? [:]
		return [
			"app": "ML Browser",
			"version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
			"build": .string(info["CFBundleVersion"] as? String ?? ""),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			"launchOptions": launchOptions
		]
	}

	func currentScreen() -> any HeadlessScreen {
		appState.isReady ? HeadlessReadyScreen() : HeadlessLaunchingScreen()
	}

	func context() -> JSONValue {
		[
			"isReady": .bool(appState.isReady),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			"launchOptions": launchOptions
		]
	}

	func waitConditions() -> [WaitCondition] {
		[
			WaitCondition("ready", summary: "The app finished launching.") { [appState] _ in
				appState.isReady
			}
		]
	}
}

/// Before `AppState` is ready there is nothing a user can do.
@MainActor
struct HeadlessLaunchingScreen: HeadlessScreen {
	var route: Route { "launching" }
	func actions() -> [HeadlessAction] { [] }
}

/// The app has launched. Which screen that actually is — the paywall, onboarding, the browser — is
/// derived in PR 3; until then this route claims nothing beyond readiness.
@MainActor
struct HeadlessReadyScreen: HeadlessScreen {
	var route: Route { "ready" }
	func actions() -> [HeadlessAction] { [] }
}
#endif
