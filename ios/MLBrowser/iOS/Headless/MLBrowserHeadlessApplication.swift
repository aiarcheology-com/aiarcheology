//
//  MLBrowserHeadlessApplication.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Combine
import Foundation
import HeadlessKit

/// ML Browser as a headless client sees it: screens derived from the real `AppState`.
///
/// `#if DEBUG` rather than headless-only, so the ordinary Debug build — the unit-test host —
/// compiles it. Only the headless entry point ever instantiates it.
///
/// Every action calls the method the UI calls for the same user intent; see
/// `specification/HEADLESS.md` for the routes and what each one offers.
@MainActor
final class MLBrowserHeadlessApplication: HeadlessApplication {

	private let appState: AppState
	private let launchOptions: JSONValue
	/// The gates' memory of having shown the app proper, kept here because it is `@State` in them.
	private var hasEverShownContent = false

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
		let decision = routeDecision()
		let route = decision.route
		if HeadlessRouteDecision.showsContent(route) {
			hasEverShownContent = true
		}
		switch route {
		case .launching: return HeadlessLaunchingScreen()
		case .gate: return HeadlessGateScreen(decision: decision)
		case .tour: return HeadlessTourScreen(tour: appState.tour)
		case .consent: return HeadlessConsentScreen(analytics: appState.analytics)
		case .home: return HeadlessHomeScreen(chromeState: appState.chromeState)
		case .drawer: return HeadlessDrawerScreen(appState: appState)
		}
	}

	func context() -> JSONValue {
		let decision = routeDecision()
		return [
			"isReady": .bool(appState.isReady),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			"launchOptions": launchOptions,
			"gate": decision.gateInputs,
			"auth": [
				"gate": .string(appState.authState.gate.headlessName),
				"usesRealAuth": .bool(appState.usesRealAuth)
			]
		]
	}

	func waitConditions() -> [WaitCondition] {
		let appState = appState
		return [
			WaitCondition("ready", summary: "The app finished launching.") { _ in
				appState.isReady
			},
			WaitCondition(
				"model-loaded",
				summary: "The model's driver is loaded and registered.",
				parameters: [ParameterSpec("id", .string, summary: "The model id from the drawer.")]
			) { arguments in
				guard let id = UUID(uuidString: try arguments.string("id")) else {
					throw HeadlessError(.invalidArgument, "'id' is not a model id")
				}
				return HeadlessDrawerScreen.isLoaded(id, in: appState.deep)
			}
		]
	}

	private func routeDecision() -> HeadlessRouteDecision {
		HeadlessRouteDecision(
			isReady: appState.isReady,
			isPaymentsSurfaceEnabled: appState.subscriptionState.isPaymentsSurfaceEnabled,
			isSubscribed: appState.subscriptionState.isSubscribed,
			freeAccess: appState.freeAccess.availability,
			freeAccessPrompt: appState.freeAccess.duePrompt,
			isWelcomePresented: appState.freeAccess.isWelcomePresented,
			isDay0AcknowledgementPending: appState.freeAccess.isDay0AcknowledgementPending,
			isIntroductionOwed: appState.tour.isIntroductionOwed,
			isTourActive: appState.tour.isActive,
			isTourPendingOrRunning: appState.tour.isPendingOrRunning,
			consentPresentation: appState.analytics.consentPresentation,
			isAskDeferredAfterSignOut: appState.analytics.isAskDeferredAfterSignOut,
			isDrawerOpen: appState.chromeState.presentedSideMenu,
			hasEverShownContent: hasEverShownContent
		)
	}
}

private extension HeadlessRouteDecision {
	/// The inputs every route depends on, reported with every response so a client can see why the
	/// app is where it is — and notice when a default it relied on has moved.
	var gateInputs: JSONValue {
		[
			"isPaymentsSurfaceEnabled": .bool(isPaymentsSurfaceEnabled),
			"isSubscribed": .bool(isSubscribed),
			"freeAccess": .string(freeAccess.headlessName),
			// The same single source the gate uses: the payments flag picks the prompt or the introduction.
			"welcomeDue": .bool(WelcomePresentation.due(
				isPaymentsSurfaceEnabled: isPaymentsSurfaceEnabled,
				freeAccessPrompt: freeAccessPrompt,
				isIntroductionOwed: isIntroductionOwed
			) != nil),
			"isDay0AcknowledgementPending": .bool(isDay0AcknowledgementPending),
			"tourPendingOrRunning": .bool(isTourPendingOrRunning),
			"consent": .string(consentPresentation.headlessName)
		]
	}
}

// MARK: - Screens

/// Before `AppState` is ready there is nothing a user can do.
@MainActor
struct HeadlessLaunchingScreen: HeadlessScreen {
	var route: Route { "launching" }
	func actions() -> [HeadlessAction] { [] }
}

/// A root gate the headless build cannot act on yet. Read-only by design: the orchestration that
/// raises these screens still lives in the gate views, and copying it here would drift.
@MainActor
struct HeadlessGateScreen: HeadlessScreen {
	let decision: HeadlessRouteDecision
	var route: Route { "gate" }
	func state() -> JSONValue { decision.gateInputs }
	func actions() -> [HeadlessAction] { [] }
}

@MainActor
struct HeadlessTourScreen: HeadlessScreen {
	let tour: TourState

	var route: Route { "tour" }

	func state() -> JSONValue {
		["active": .bool(tour.isActive), "step": .number(Double(tour.currentIndex))]
	}

	func actions() -> [HeadlessAction] {
		[
			HeadlessAction("skip", summary: "Skip the tour.") { [tour] _ in
				// The UI starts an armed tour as soon as content shows, and the user skips it from
				// there: the same two calls, with nothing a user could do in between.
				if tour.isActive == false {
					tour.startIfArmed()
				}
				tour.skip()
				return nil
			}
		]
	}
}

@MainActor
struct HeadlessConsentScreen: HeadlessScreen {
	let analytics: AnalyticsState

	var route: Route { "consent" }

	/// `.pending` holds the question until the analytics scope resolves; nothing is answerable then.
	private var isPending: Bool { analytics.consentPresentation == .pending }

	func state() -> JSONValue {
		["pending": .bool(isPending)]
	}

	func actions() -> [HeadlessAction] {
		guard isPending == false else { return [] }
		return [
			HeadlessAction("allow", summary: "Allow anonymous analytics.") { [analytics] _ in
				analytics.chooseAnalytics(enabled: true)
				return nil
			},
			HeadlessAction("deny", summary: "Do not allow analytics.") { [analytics] _ in
				analytics.chooseAnalytics(enabled: false)
				return nil
			}
		]
	}
}

@MainActor
struct HeadlessHomeScreen: HeadlessScreen {
	let chromeState: AppChromeState

	var route: Route { "home" }

	func actions() -> [HeadlessAction] {
		[
			HeadlessAction("open-drawer", summary: "Open the menu.", navigatesTo: "drawer") { [chromeState] _ in
				// The toolbar's menu button.
				chromeState.togglingSideMenu()
				return nil
			}
		]
	}
}

@MainActor
struct HeadlessDrawerScreen: HeadlessScreen {
	let appState: AppState

	var route: Route { "drawer" }

	/// How long `enable` waits for the model to load before giving up.
	static let loadTimeout: Duration = .seconds(120)

	func state() -> JSONValue {
		let deep = appState.deep
		let models: [JSONValue] = Self.listedModels(in: appState).map { configuration in
			[
				"id": .string(configuration.entityId.uuidString),
				"name": .string(DeepConfiguration.displayName(from: configuration.modelDescription)),
				"type": .string(configuration.modelType.rawValue),
				"enabled": .bool(configuration.enabled),
				// The menu disables the switch of a model without a type; `enable` refuses it too.
				"canEnable": .bool(configuration.modelType != .invalid),
				"loaded": .bool(Self.isLoaded(configuration.entityId, in: deep))
			]
		}
		return ["models": .array(models)]
	}

	func actions() -> [HeadlessAction] {
		let appState = appState
		let id = ParameterSpec("id", .string, summary: "The model id, from state.models.")
		return [
			HeadlessAction("close", summary: "Close the menu.", navigatesTo: "home") { _ in
				appState.chromeState.togglingSideMenu()
				return nil
			},
			HeadlessAction("enable", summary: "Switch a model on and wait until it has loaded.", parameters: [id]) { arguments in
				try await Self.setEnabled(true, arguments: arguments, appState: appState)
			},
			HeadlessAction("disable", summary: "Switch a model off.", parameters: [id]) { arguments in
				try await Self.setEnabled(false, arguments: arguments, appState: appState)
			}
		]
	}

	/// The drawer's own list: the same fetch its `@FetchRequest` runs.
	static func listedModels(in appState: AppState) -> [DeepConfiguration] {
		let context = appState.dataController.container.viewContext
		do {
			return try context.fetch(DeepConfiguration.drawerListFetchRequest())
		} catch {
			LoggingPolicy.error("Headless drawer could not list models", error: error, logger: .configuration)
			return []
		}
	}

	static func isLoaded(_ id: UUID, in deep: DeepState) -> Bool {
		(deep.drivers.detectors + deep.drivers.classificators).contains { $0.id == id }
	}

	/// The drawer switch's own call, then — for `enable` — the load it sets off: the action returns
	/// once the driver is registered, or fails with the load error the app publishes.
	private static func setEnabled(_ enabled: Bool, arguments: Arguments, appState: AppState) async throws -> JSONValue? {
		let rawID = try arguments.string("id")
		guard let id = UUID(uuidString: rawID),
			  let configuration = listedModels(in: appState).first(where: { $0.entityId == id }) else {
			throw HeadlessError(.invalidArgument, "no model '\(rawID)' in the menu")
		}
		let deep = appState.deep
		let loadFailure = LoadFailureProbe(deep: deep)
		do {
			try deep.setEnabled(enabled, for: configuration)
		} catch DeepState.EnableError.invalidModelType {
			throw HeadlessError(.invalidArgument, "'\(rawID)' has no model type yet; the menu does not let it be switched on")
		}
		let settled = try await HeadlessWait.until(timeout: enabled ? loadTimeout : .seconds(10)) {
			loadFailure.error != nil || isLoaded(id, in: deep) == enabled
		}
		// `DeepState` publishes errors from every model and from cleanup, not only this load, so an error
		// fails the action only if this model did not reach the requested state after all.
		if let error = loadFailure.error, isLoaded(id, in: deep) != enabled {
			throw HeadlessError(.actionFailed, "the model did not \(enabled ? "load" : "unload"): \(error.localizedDescription)")
		}
		guard settled else {
			throw HeadlessError(.timeout, "the model did not \(enabled ? "load" : "unload") in time")
		}
		return ["id": .string(id.uuidString), "loaded": .bool(isLoaded(id, in: deep))]
	}
}

/// Watches `DeepState` for a load error published after it was created.
@MainActor
private final class LoadFailureProbe {
	private(set) var error: Error?
	private var subscription: AnyCancellable?

	init(deep: DeepState) {
		// `dropFirst`: the publisher replays the current value, which may be an old error.
		subscription = deep.deepStateErrorPublisher
			.dropFirst()
			.compactMap { $0 }
			.sink { [weak self] error in
				self?.error = error
			}
	}
}

// MARK: - Stable names for reported state
//
// Spelled out rather than taken from `String(describing:)`: scenarios assert on these strings, and
// they must not follow a case rename or depend on how a build renders a type.

private extension AuthGate {
	var headlessName: String {
		switch self {
		case .checkingSession: "checkingSession"
		case .signedOut: "signedOut"
		case .offline: "offline"
		case .ready: "ready"
		}
	}
}

private extension FreeAccessAvailability {
	var headlessName: String {
		switch self {
		case .undetermined: "undetermined"
		case .open: "open"
		case .closed: "closed"
		}
	}
}

private extension AnalyticsConsentPresentation {
	var headlessName: String {
		switch self {
		case .pending: "pending"
		case .ask: "ask"
		case .resolved: "resolved"
		case .unavailable: "unavailable"
		}
	}
}
#endif
