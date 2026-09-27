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

/// ML Browser as a headless client sees it: screens derived from the real `AppState`, handed in as
/// `HeadlessAppParts`.
///
/// `#if DEBUG` rather than headless-only, so the ordinary Debug build — the unit-test host —
/// compiles it. Only the headless entry point ever instantiates it.
///
/// Every action calls the method the UI calls for the same user intent; see
/// `specification/HEADLESS.md` for the routes and what each one offers.
@MainActor
final class MLBrowserHeadlessApplication: HeadlessApplication {

	private let parts: HeadlessAppParts
	private let launchOptions: JSONValue
	/// The root gate's orchestration — the object `SubscriptionGateView` runs on, one per window. The
	/// headless build has exactly one window, so it owns exactly one.
	private let gate: SubscriptionGateCoordinator
	/// `AnalyticsChoiceGate`'s memory of having rendered its content, kept here because it is
	/// `@State` in the view.
	private var hasEverShownAnalyticsContent = false
	/// Detection on staged images, for the life of the process. Headless-only, so it is kept here
	/// rather than in `AppState`; the save sheet's capture it picks is on `chromeState`, shared with the
	/// web screen.
	private let capture: StagedImageCapture

	init(parts: HeadlessAppParts, launchOptions: JSONValue) {
		self.parts = parts
		self.launchOptions = launchOptions
		self.gate = SubscriptionGateCoordinator(
			subscriptionState: parts.subscriptionState,
			freeAccess: parts.freeAccess,
			tour: parts.tour,
			analytics: parts.analytics
		)
		self.capture = StagedImageCapture(
			deep: parts.deep,
			settings: parts.settings,
			repository: parts.findingRepository,
			authState: parts.authState,
			presentation: parts.chromeState.saveFindingPresentation,
			stagedNames: parts.stagedNames,
			stagedDirectory: parts.stagedDirectory
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

	/// Every route and the transitions possible between them (AIA-0982).
	var navigationMap: NavigationMap { HeadlessNavigationMap.declaration }

	func currentScreen() -> any HeadlessScreen {
		switch routeDecision().route {
		case .launching: return HeadlessLaunchingScreen()
		case .gate: return HeadlessGateScreen(inputs: gateInputs())
		case .paywall: return HeadlessPaywallScreen(subscriptionState: parts.subscriptionState, freeAccess: parts.freeAccess)
		case .welcome: return HeadlessWelcomeScreen(gate: gate)
		case .tour: return HeadlessTourScreen(tour: parts.tour)
		case .consent: return HeadlessConsentScreen(analytics: parts.analytics)
		case .home: return HeadlessHomeScreen(chromeState: parts.chromeState, capture: capture)
		case .drawer: return HeadlessDrawerScreen(parts: parts)
		case .account:
			return HeadlessAccountScreen(parts: parts) { [unowned self] in
				self.closeTarget(for: .account)
			}
		case .saveFinding:
			return HeadlessSaveFindingScreen(parts: parts, capture: capture) { [unowned self] in
				self.closeTarget(for: .saveFinding)
			}
		case .findings:
			return HeadlessFindingsScreen(parts: parts) { [unowned self] in
				self.closeTarget(for: .findings)
			}
		case .backupConsent: return HeadlessBackupConsentScreen(findingsSync: parts.findingsSync)
		}
	}

	/// Where closing `sheet` lands, decided from the app's state at the moment a screen lists its
	/// actions — the back-up question when one is pending, otherwise what the sheet covered.
	private func closeTarget(for sheet: HeadlessRoute) -> Route {
		Route(routeDecision().route(afterClosing: sheet).rawValue)
	}

	func context() -> JSONValue {
		// For its effects: the gates settle before their inputs are reported, as they would have on
		// this render.
		_ = routeDecision()
		return [
			"isReady": .bool(parts.isReady()),
			"backendEnvironment": .string(BackendEnvironment.current.rawValue),
			"launchOptions": launchOptions,
			"gate": gateInputs(),
			// Whether analytics is actually on: the user's answer applied under the live flag. Never
			// more than this one Bool.
			"analytics": ["enabled": .bool(parts.analytics.isAnalyticsEnabled)],
			"auth": [
				"gate": .string(parts.authState.gate.headlessName),
				"usesRealAuth": .bool(parts.usesRealAuth),
				"signedIn": .bool(HeadlessAccountScreen.isSignedIn(parts.authState)),
				// The backend still holds a user, whatever the gate says: proves a sign-out really
				// ended the session.
				"accountPresent": .bool(parts.authState.isProviderSignedIn)
			]
		]
	}

	func waitConditions() -> [WaitCondition] {
		let parts = parts
		let findingID = ParameterSpec("id", .string, summary: "The finding id, from the findings list or save's result.")
		return [
			WaitCondition("ready", summary: "The app finished launching.") { _ in
				parts.isReady()
			},
			WaitCondition(
				"model-loaded",
				summary: "The model's driver is loaded and registered.",
				parameters: [ParameterSpec("id", .string, summary: "The model id from the drawer.")]
			) { arguments in
				guard let id = UUID(uuidString: try arguments.string("id")) else {
					throw HeadlessError(.invalidArgument, "'id' is not a model id")
				}
				return HeadlessDrawerScreen.isLoaded(id, in: parts.deep)
			},
			WaitCondition("signed-in", summary: "A validated account is signed in.") { _ in
				HeadlessAccountScreen.isSignedIn(parts.authState)
			},
			WaitCondition(
				"backed-up",
				summary: "The finding is backed up: the state its row's icon shows.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return parts.findingsSync.backupStates[id] == .backedUp
			},
			WaitCondition(
				"finding-present",
				summary: "A ready finding with this id is in the local store.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return HeadlessFindingsScreen.isPresent(id, in: parts)
			},
			WaitCondition(
				"finding-absent",
				summary: "No ready finding with this id is in the local store.",
				parameters: [findingID]
			) { arguments in
				let id = try HeadlessFindingsScreen.findingID(arguments)
				return HeadlessFindingsScreen.isPresent(id, in: parts) == false
			}
		]
	}

	/// The route decision `currentScreen()` acts on: the unit tests' window onto it. It has the same
	/// side effects as listing the current screen — the root gates settle, as on a render.
	func currentDecision() -> HeadlessRouteDecision {
		routeDecision()
	}

	/// The screen the app shows now, after the root gates have done what their views would have done
	/// on this render.
	///
	/// Only once `AppState` is ready: the gate views are not mounted before that
	/// (`MLBrowser.authGatedContent`), so nothing may be raised, remembered or started earlier.
	private func routeDecision() -> HeadlessRouteDecision {
		let isDrawerOpen = parts.chromeState.presentedSideMenu
		// The drawer view's own sheets; `AppChromeState` dismisses them whenever the drawer closes.
		let presentation = parts.chromeState.drawerPresentation
		if parts.isReady() {
			gate.reconcile()
		}
		let decision = HeadlessRouteDecision(
			isReady: parts.isReady(),
			display: gate.display,
			presentedWelcome: gate.presentedPrompt,
			isDay0AcknowledgementPending: parts.freeAccess.isDay0AcknowledgementPending,
			isTourPendingOrRunning: parts.tour.isPendingOrRunning,
			consentPresentation: parts.analytics.consentPresentation,
			isAskDeferredAfterSignOut: parts.analytics.isAskDeferredAfterSignOut,
			isDrawerOpen: isDrawerOpen,
			hasEverShownAnalyticsContent: hasEverShownAnalyticsContent,
			isAccountPresented: presentation.isAccountPresented,
			isSaveFindingPresented: parts.chromeState.saveFindingPresentation.isPresented,
			isFindingsPresented: presentation.isFindingsPresented,
			isBackupConsentPending: parts.findingsSync.backupConsentRequest != nil
		)
		if parts.isReady() && decision.analyticsGateShowsContent {
			hasEverShownAnalyticsContent = true
		}
		return decision
	}

	/// The inputs every gate route depends on, reported with every response so a client can see why
	/// the app is where it is — and notice when a default it relied on has moved.
	private func gateInputs() -> JSONValue {
		let subscription = parts.subscriptionState
		let freeAccess = parts.freeAccess
		return [
			"isPaymentsSurfaceEnabled": .bool(subscription.isPaymentsSurfaceEnabled),
			"isSubscribed": .bool(subscription.isSubscribed),
			"freeAccess": .string(freeAccess.availability.headlessName),
			"welcomeDue": .bool(gate.dueWelcome != nil),
			"display": .string(gate.display.headlessName),
			"welcome": gate.presentedPrompt.map { .string($0.headlessName) } ?? .null,
			"isDay0AcknowledgementPending": .bool(freeAccess.isDay0AcknowledgementPending),
			"tourPendingOrRunning": .bool(parts.tour.isPendingOrRunning),
			"consent": .string(parts.analytics.consentPresentation.headlessName)
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
				// The button's own call. Lowering the screen releases the claim and starts an armed
				// tour in the same call, as it does in the app.
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
	let parts: HeadlessAppParts

	var route: Route { "drawer" }

	/// How long `enable` waits for the model to load before giving up.
	static let loadTimeout: Duration = .seconds(120)

	func state() -> JSONValue {
		let deep = parts.deep
		let models: [JSONValue] = Self.listedModels(in: parts).map { configuration in
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
		let parts = parts
		// The drawer's sheets: the model the drawer view binds to.
		let presentation = parts.chromeState.drawerPresentation
		let id = ParameterSpec("id", .string, summary: "The model id, from state.models.")
		var actions = [
			HeadlessAction("close", summary: "Close the menu.", navigatesTo: "home") { _ in
				parts.chromeState.togglingSideMenu()
				return nil
			},
			HeadlessAction("enable", summary: "Switch a model on and wait until it has loaded.", parameters: [id]) { arguments in
				try await Self.setEnabled(true, arguments: arguments, parts: parts)
			},
			HeadlessAction("disable", summary: "Switch a model off.", parameters: [id]) { arguments in
				try await Self.setEnabled(false, arguments: arguments, parts: parts)
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
			FindingScreenshotStore.sweepOrphans(
				in: parts.dataController.container.viewContext,
				directory: parts.findingsDirectory
			)
			await parts.findingsSync.syncNow()?.value
			return nil
		})
		// The footer's own switch: a Sign In row while anonymous, the account row once validated, and
		// nothing to tap while auth is resolving or offline.
		switch parts.authState.effectiveContext {
		case .anonymous, .validated:
			actions.append(HeadlessAction(
				"open-account",
				summary: "Open the account screen: sign in, or the signed-in account.",
				navigatesTo: "account"
			) { _ in
				// The footer's own choice: the sign-in sheet while anonymous, Settings once validated.
				presentation.presentAccount(for: parts.authState.effectiveContext, usesRealAuth: parts.usesRealAuth)
				return nil
			})
		case .suspended, .indeterminate:
			break
		}
		return actions
	}

	/// The drawer's own list: the same fetch its `@FetchRequest` runs.
	static func listedModels(in parts: HeadlessAppParts) -> [DeepConfiguration] {
		let context = parts.dataController.container.viewContext
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
	private static func setEnabled(_ enabled: Bool, arguments: Arguments, parts: HeadlessAppParts) async throws -> JSONValue? {
		let rawID = try arguments.string("id")
		guard let id = UUID(uuidString: rawID),
			  let configuration = listedModels(in: parts).first(where: { $0.entityId == id }) else {
			throw HeadlessError(.invalidArgument, "no model '\(rawID)' in the menu")
		}
		let deep = parts.deep
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
