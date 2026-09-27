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
	/// The root gate's orchestration — the object `SubscriptionGateView` runs on, one per window. The
	/// headless build has exactly one window, so it owns exactly one.
	private let gate: SubscriptionGateCoordinator
	/// `AnalyticsChoiceGate`'s memory of having rendered its content, kept here because it is
	/// `@State` in the view.
	private var hasEverShownAnalyticsContent = false
	/// What the drawer's views present, kept here because it is `@State` in them.
	private let presentation = HeadlessPresentation()
	/// Detection on staged images and the save sheet's pending capture, for the life of the process.
	/// Headless-only, like `presentation`, so it is kept here rather than in `AppState`.
	private let capture: StagedImageCapture

	init(appState: AppState, launchOptions: JSONValue) {
		self.appState = appState
		self.launchOptions = launchOptions
		self.gate = SubscriptionGateCoordinator(
			subscriptionState: appState.subscriptionState,
			freeAccess: appState.freeAccess,
			tour: appState.tour,
			analytics: appState.analytics
		)
		self.capture = StagedImageCapture(
			deep: appState.deep,
			settings: appState.settings,
			repository: appState.findingRepository,
			authState: appState.authState,
			stagedNames: HeadlessLaunchOptions.current.stagedImages
		)
	}

	var metadata: [String: JSONValue] {
		let info = Bundle.main.infoDictionary ?? [:]
		return [
			"app": "ML Browser",
			"version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
			"build": .string(info["CFBundleVersion"] as? String ?? ""),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			// The headless build is built without a Sentry DSN; a scenario can check it was.
			"crashReporting": .bool((info["SentryDSN"] as? String).map { $0.isEmpty == false } ?? false),
			"launchOptions": launchOptions
		]
	}

	func currentScreen() -> any HeadlessScreen {
		switch routeDecision().route {
		case .launching: return HeadlessLaunchingScreen()
		case .gate: return HeadlessGateScreen(inputs: gateInputs())
		case .paywall: return HeadlessPaywallScreen(subscriptionState: appState.subscriptionState, freeAccess: appState.freeAccess)
		case .welcome: return HeadlessWelcomeScreen(gate: gate)
		case .tour: return HeadlessTourScreen(tour: appState.tour)
		case .consent: return HeadlessConsentScreen(analytics: appState.analytics)
		case .home: return HeadlessHomeScreen(chromeState: appState.chromeState, capture: capture)
		case .drawer: return HeadlessDrawerScreen(appState: appState, presentation: presentation)
		case .account:
			return HeadlessAccountScreen(appState: appState, presentation: presentation) { [unowned self] in
				self.closeTarget(for: .account)
			}
		case .saveFinding:
			return HeadlessSaveFindingScreen(appState: appState, capture: capture) { [unowned self] in
				self.closeTarget(for: .saveFinding)
			}
		case .findings:
			return HeadlessFindingsScreen(appState: appState, presentation: presentation) { [unowned self] in
				self.closeTarget(for: .findings)
			}
		case .backupConsent: return HeadlessBackupConsentScreen(findingsSync: appState.findingsSync)
		}
	}

	/// Where closing `sheet` lands, decided from the app's state at the moment a screen lists its
	/// actions — the back-up question when one is pending, otherwise what the sheet covered.
	private func closeTarget(for sheet: HeadlessRoute) -> Route {
		Route(routeDecision().route(afterClosing: sheet).rawValue)
	}

	func context() -> JSONValue {
		_ = routeDecision()
		return [
			"isReady": .bool(appState.isReady),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			"launchOptions": launchOptions,
			"gate": gateInputs(),
			// Whether analytics is actually on: the user's answer applied under the live flag. Never
			// more than this one Bool.
			"analytics": ["enabled": .bool(appState.analytics.isAnalyticsEnabled)],
			"auth": [
				"gate": .string(appState.authState.gate.headlessName),
				"usesRealAuth": .bool(appState.usesRealAuth),
				"signedIn": .bool(HeadlessAccountScreen.isSignedIn(appState.authState)),
				// The backend still holds a user, whatever the gate says: proves a sign-out really
				// ended the session.
				"accountPresent": .bool(appState.authState.isProviderSignedIn)
			]
		]
	}

	func waitConditions() -> [WaitCondition] {
		let appState = appState
		let findingID = ParameterSpec("id", .string, summary: "The finding id, from the findings list or save's result.")
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
			},
			WaitCondition("signed-in", summary: "A validated account is signed in.") { _ in
				HeadlessAccountScreen.isSignedIn(appState.authState)
			},
			WaitCondition(
				"backed-up",
				summary: "The finding is backed up: the state its row's icon shows.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return appState.findingsSync.backupStates[id] == .backedUp
			},
			WaitCondition(
				"finding-present",
				summary: "A ready finding with this id is in the local store.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return HeadlessFindingsScreen.isPresent(id, in: appState)
			},
			WaitCondition(
				"finding-absent",
				summary: "No ready finding with this id is in the local store.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return HeadlessFindingsScreen.isPresent(id, in: appState) == false
			}
		]
	}

	/// The screen the app shows now, after the root gates have done what their views would have done
	/// on this render.
	///
	/// Only once `AppState` is ready: the gate views are not mounted before that
	/// (`MLBrowser.authGatedContent`), so nothing may be raised, remembered or started earlier.
	private func routeDecision() -> HeadlessRouteDecision {
		let isDrawerOpen = appState.chromeState.presentedSideMenu
		presentation.dismissSheetsIfDrawerClosed(isDrawerOpen: isDrawerOpen)
		if appState.isReady {
			gate.reconcile()
		}
		let decision = HeadlessRouteDecision(
			isReady: appState.isReady,
			display: gate.display,
			presentedWelcome: gate.presentedPrompt,
			isDay0AcknowledgementPending: appState.freeAccess.isDay0AcknowledgementPending,
			isTourPendingOrRunning: appState.tour.isPendingOrRunning,
			consentPresentation: appState.analytics.consentPresentation,
			isAskDeferredAfterSignOut: appState.analytics.isAskDeferredAfterSignOut,
			isDrawerOpen: isDrawerOpen,
			hasEverShownAnalyticsContent: hasEverShownAnalyticsContent,
			isAccountPresented: presentation.isAccountPresented,
			isSaveFindingPresented: capture.pendingCapture != nil,
			isFindingsPresented: presentation.isFindingsPresented,
			isBackupConsentPending: appState.findingsSync.backupConsentRequest != nil
		)
		if appState.isReady && decision.analyticsGateShowsContent {
			hasEverShownAnalyticsContent = true
		}
		return decision
	}

	/// The inputs every gate route depends on, reported with every response so a client can see why
	/// the app is where it is — and notice when a default it relied on has moved.
	private func gateInputs() -> JSONValue {
		let subscription = appState.subscriptionState
		let freeAccess = appState.freeAccess
		return [
			"isPaymentsSurfaceEnabled": .bool(subscription.isPaymentsSurfaceEnabled),
			"isSubscribed": .bool(subscription.isSubscribed),
			"freeAccess": .string(freeAccess.availability.headlessName),
			"welcomeDue": .bool(gate.dueWelcome != nil),
			"display": .string(gate.display.headlessName),
			"welcome": gate.presentedPrompt.map { .string($0.headlessName) } ?? .null,
			"isDay0AcknowledgementPending": .bool(freeAccess.isDay0AcknowledgementPending),
			"tourPendingOrRunning": .bool(appState.tour.isPendingOrRunning),
			"consent": .string(appState.analytics.consentPresentation.headlessName)
		]
	}
}

extension SubscriptionGateCoordinator {
	/// Everything `SubscriptionGateView`'s `onChange` handlers would do on this render, for a build
	/// with no view to render (AIA-0976). Headless and Debug only: the app never calls it — its view
	/// calls each handler when its own value changes.
	///
	/// The level form of those edge-triggered handlers, and equivalent to them because each is
	/// guarded or idempotent: a raise needs a presentable screen, none up and one due; a lowering
	/// needs one up that can no longer be presented, and one is only ever put up while it can be;
	/// `TourState.startIfArmed()` does nothing twice. Repeated until nothing moves, as a handler's
	/// effect is another render.
	func reconcile() {
		for _ in 0..<8 {
			let before = ReconcileSnapshot(self)
			displayChanged(to: display)
			canPresentPromptChanged(to: canPresentPrompt)
			duePromptChanged()
			introductionOwedChanged()
			welcomeClaimsChanged()
			if ReconcileSnapshot(self) == before { return }
		}
		LoggingPolicy.error("Headless gate reconcile did not settle", logger: .lifecycle)
	}

	/// What the handlers can move.
	private struct ReconcileSnapshot: Equatable {
		let display: RootGateDisplay
		let canPresentPrompt: Bool
		let presentedPrompt: WelcomePresentation?
		let hasEverShownContent: Bool
		let isTourPendingOrRunning: Bool
		let isTourActive: Bool
		let isWelcomePresented: Bool

		@MainActor
		init(_ gate: SubscriptionGateCoordinator) {
			display = gate.display
			canPresentPrompt = gate.canPresentPrompt
			presentedPrompt = gate.presentedPrompt
			hasEverShownContent = gate.hasEverShownContent
			isTourPendingOrRunning = gate.tour.isPendingOrRunning
			isTourActive = gate.tour.isActive
			isWelcomePresented = gate.freeAccess.isWelcomePresented
		}
	}
}

// MARK: - Screens

/// Before `AppState` is ready there is nothing a user can do.
@MainActor
struct HeadlessLaunchingScreen: HeadlessScreen {
	var route: Route { "launching" }
	func actions() -> [HeadlessAction] { [] }
}

/// The root gate's hold while the free-access window is still being read: the gate renders a
/// spinner and there is nothing to do but wait.
@MainActor
struct HeadlessGateScreen: HeadlessScreen {
	let inputs: JSONValue
	var route: Route { "gate" }
	func state() -> JSONValue { inputs }
	func actions() -> [HeadlessAction] { [] }
}

/// The paywall as the root gate shows it. No actions: purchasing needs a real App Store purchase
/// sheet, and restoring would raise the App Store sign-in, so neither is automatable. The headless
/// build does not drive `PaywallView`, so products are not loaded and `paywall.shown` is not sent.
@MainActor
struct HeadlessPaywallScreen: HeadlessScreen {
	let subscriptionState: SubscriptionState
	let freeAccess: FreeAccessState

	var route: Route { "paywall" }

	func state() -> JSONValue {
		[
			"isSubscribed": .bool(subscriptionState.isSubscribed),
			// What the wall's copy keys on: only a window that actually ran out is told so.
			"expired": .bool(freeAccess.hasSpentWindow)
		]
	}

	func actions() -> [HeadlessAction] { [] }
}

/// A Welcome screen the root gate has raised over the app. `continue` is the screen's button.
///
/// `continue` declares no destination: after it the app shows the tour when one is owed, and the
/// consent question or the app proper when it is not, which `route` in the response reports.
@MainActor
struct HeadlessWelcomeScreen: HeadlessScreen {
	let gate: SubscriptionGateCoordinator

	var route: Route { "welcome" }

	func state() -> JSONValue {
		switch gate.presentedPrompt {
		case let .freeAccess(prompt): ["offer": "freeAccess", "days": .number(Double(prompt.days))]
		case .introduction: ["offer": "introduction"]
		case nil: [:]
		}
	}

	func actions() -> [HeadlessAction] {
		guard let presented = gate.presentedPrompt else { return [] }
		return [
			HeadlessAction("continue", summary: "Continue past the Welcome screen.") { [gate] _ in
				// The button's own call. The tour the lowering starts is picked up by the next
				// reconcile, as the view's handlers pick it up on the next render.
				gate.continueWelcome(presented)
				return nil
			}
		]
	}
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
				// The root gate's coordinator has already started it, as the view's does.
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
	let capture: StagedImageCapture

	var route: Route { "home" }

	func actions() -> [HeadlessAction] {
		let capture = capture
		var actions = [
			HeadlessAction("open-drawer", summary: "Open the menu.", navigatesTo: "drawer") { [chromeState] _ in
				// The toolbar's menu button.
				chromeState.togglingSideMenu()
				return nil
			}
		]
		// Staged images stand in for the page snapshot the web screen detects on; with none staged
		// there is nothing to detect on.
		if capture.hasStagedImages {
			let image = ParameterSpec("image", .string, summary: "A staged image name, from launchOptions.stagedImages.")
			actions.append(HeadlessAction(
				"detect-image",
				summary: "Run detection with the enabled models on a staged image.",
				parameters: [image]
			) { arguments in
				try await Self.detect(arguments: arguments, capture: capture)
			})
		}
		// Tapping a displayed box: only while a detection pass is held.
		if capture.frame != nil {
			let detection = ParameterSpec("detection", .integer, summary: "The index from detect-image's result.")
			actions.append(HeadlessAction(
				"pick",
				summary: "Pick a detection and open the save sheet.",
				parameters: [detection],
				navigatesTo: "save-finding"
			) { arguments in
				do {
					try capture.pick(index: arguments.integer("detection"))
				} catch StagedImageCapture.Failure.detectionOutOfRange {
					throw HeadlessError(.invalidArgument, "'detection' is not an index from the last detect-image result")
				} catch let failure as StagedImageCapture.Failure {
					throw HeadlessError(.actionFailed, "the detection could not be picked (\(failure.headlessName))")
				}
				return nil
			})
		}
		return actions
	}

	/// Detection's result: labels and confidences only — never a box, image data, or a path.
	private static func detect(arguments: Arguments, capture: StagedImageCapture) async throws -> JSONValue? {
		let detections: [StagedImageCapture.Detection]
		do {
			detections = try await capture.detect(imageNamed: arguments.string("image"))
		} catch StagedImageCapture.Failure.notStaged {
			throw HeadlessError(.invalidArgument, "'image' is not a staged image of this launch")
		} catch let failure as StagedImageCapture.Failure {
			throw HeadlessError(.actionFailed, "the staged image could not be read (\(failure.headlessName))")
		}
		return ["detections": .array(detections.map { detection in
			[
				"index": .number(Double(detection.index)),
				"label": .string(detection.label),
				"confidence": .number(HeadlessSaveFindingScreen.rounded(detection.confidence))
			]
		})]
	}
}

@MainActor
struct HeadlessDrawerScreen: HeadlessScreen {
	let appState: AppState
	let presentation: HeadlessPresentation

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
		let presentation = presentation
		let id = ParameterSpec("id", .string, summary: "The model id, from state.models.")
		var actions = [
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
		// The Findings row, always in the menu; the tour disables it, but the tour has its own route.
		actions.append(HeadlessAction(
			"open-findings",
			summary: "Open the findings list, and wait for the sync its opening starts.",
			navigatesTo: "findings"
		) { _ in
			presentation.isFindingsPresented = true
			// What the list does as it appears: heal leftover screenshot files, then ask the server.
			FindingScreenshotStore.sweepOrphans(in: appState.dataController.container.viewContext)
			await appState.findingsSync.syncNow()?.value
			return nil
		})
		// The footer's own switch: a Sign In row while anonymous, the account row once validated, and
		// nothing to tap while auth is resolving or offline.
		switch appState.authState.effectiveContext {
		case .anonymous, .validated:
			actions.append(HeadlessAction(
				"open-account",
				summary: "Open the account screen: sign in, or the signed-in account.",
				navigatesTo: "account"
			) { _ in
				presentation.isAccountPresented = true
				return nil
			})
		case .suspended, .indeterminate:
			break
		}
		return actions
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

/// Not `private`: the account screen reports the gate when a sign-in does not settle.
extension AuthGate {
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

/// Not `private`: the save-finding screen reports these too.
extension StagedImageCapture.Failure {
	var headlessName: String {
		switch self {
		case .notStaged: "notStaged"
		case .missingFile: "missingFile"
		case .undecodableImage: "undecodableImage"
		case .noFrame: "noFrame"
		case .detectionOutOfRange: "detectionOutOfRange"
		case .noPendingCapture: "noPendingCapture"
		}
	}
}

private extension RootGateDisplay {
	var headlessName: String {
		switch self {
		case .content: "content"
		case .wall: "wall"
		case .wallOverContent: "wallOverContent"
		case .hold: "hold"
		}
	}
}

private extension WelcomePresentation {
	var headlessName: String {
		switch self {
		case .freeAccess: "freeAccess"
		case .introduction: "introduction"
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
