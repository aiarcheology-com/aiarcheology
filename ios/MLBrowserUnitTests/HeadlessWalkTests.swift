//
//  HeadlessWalkTests.swift
//  MLBrowserUnitTests
//
//  AIA-0982.
//

import HeadlessKit
import UIKit
import XCTest
@testable import ML_Browser

/// The navigation map against the adapters: a real `MLBrowserHeadlessApplication`, built from
/// isolated parts and driven in-process only through headless commands, walks the states the
/// scenarios reach. At every state the live actions' transitions must be in the map (`map`'s
/// `undeclared`), and every move — by an action or on the app's own — must be a declared edge.
///
/// Isolation: in-memory Core Data, mock auth, the mock subscription and the ephemeral free-access
/// anchor, a stub detector on a staged PNG, a stubbed Worker, and scratch directories for staged
/// images, the findings sweep and the sync ledger. The walk never performs `save`: the screenshot
/// store writes to the app's real Documents directory, which the parts do not redirect. `sign-in`
/// is not walkable either: mock auth refuses the handler, so its edges are verified only by the
/// sign-in scenario.
@MainActor
final class HeadlessWalkTests: XCTestCase {

	/// Routes the walk cannot reach, each with the reason. With the visited routes they must make up
	/// every `HeadlessRoute`, so a new route forces a decision: walk it, or say why not.
	private static let unvisited: [HeadlessRoute: String] = [
		.backupConsent: "needs a finding saved before sign-in and an account change through sync; the walk "
			+ "saves nothing and cannot sign in. Its entry edges are covered by the sheet-exit enumeration "
			+ "(HeadlessNavigationMapTests) and the scenarios"
	]

	private var scratch: URL!
	private var realDirectoriesBefore: [String: [String]?] = [:]

	override func setUp() async throws {
		try await super.setUp()
		StubWorkerProtocol.reset()
		scratch = FileManager.default.temporaryDirectory
			.appending(path: "HeadlessWalkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		realDirectoriesBefore = Self.realDirectoryListings()
	}

	override func tearDown() async throws {
		XCTAssertEqual(
			Self.realDirectoryListings(),
			realDirectoriesBefore,
			"the walk touched the app's real screenshot or staging directory"
		)
		try? FileManager.default.removeItem(at: scratch)
		scratch = nil
		StubWorkerProtocol.reset()
		try await super.tearDown()
	}

	// MARK: - Walks

	/// Every walk, once, and then every route is walked or explained. One test rather than one per
	/// walk: the coverage check needs all of them, and XCTest does not order tests, so separate tests
	/// would run each walk twice. Every failure names its walk.
	func test_theWalks_stayOnTheMap_andEveryRouteIsWalkedOrExplained() async throws {
		let walks: [(name: String, walk: () async throws -> Set<HeadlessRoute>)] = [
			("fresh", { try await self.walkAFreshInstall() }),
			("signed-in", { try await self.walkASignedInAccount() }),
			("wall", { try await self.walkTheWall() }),
			("expiry", { try await self.walkAccessRunningOutUnderASheet() }),
			("payments-off", { try await self.walkPaymentsOff() })
		]
		var visited: Set<HeadlessRoute> = []
		var stopped: [String] = []
		for (name, walk) in walks {
			do {
				visited.formUnion(try await walk())
			} catch {
				stopped.append(name)
				XCTFail("[walk \(name)] stopped: \(error)")
			}
		}

		// A walk that stopped visited only part of its routes; the coverage check would only repeat that.
		guard stopped.isEmpty else { return }
		XCTAssertTrue(
			visited.isDisjoint(with: Self.unvisited.keys),
			"walked routes are listed as unvisited: \(visited.intersection(Self.unvisited.keys).map(\.rawValue))"
		)
		XCTAssertEqual(
			visited.union(Self.unvisited.keys),
			Set(HeadlessRoute.allCases),
			"routes neither walked nor explained: \(Set(HeadlessRoute.allCases).subtracting(visited.union(Self.unvisited.keys)).map(\.rawValue))"
		)
	}

	/// launching → gate → welcome (the free-access offer) → tour → consent → home → drawer → account
	/// (anonymous) → drawer → findings → drawer → home → detect → save-finding → home.
	private func walkAFreshInstall() async throws -> Set<HeadlessRoute> {
		let walker = try await makeWalker(
			name: "fresh",
			auth: MockAuthProvider(outcome: .signedOut),
			startFreeAccess: false,
			answersConsent: false
		)
		try await walker.observe(expecting: .launching)

		walker.ready.isReady = true
		try await walker.settle(at: .gate)

		walker.world.startFreeAccess()
		let welcome = try await walker.settle(at: .welcome)
		XCTAssertEqual(welcome.state.value(at: "/offer"), .string("freeAccess"), "[walk fresh]")

		try await walker.perform("continue", arrivesAt: .tour)
		try await walker.perform("skip", arrivesAt: .consent)
		try await walker.perform("deny", arrivesAt: .home)
		try await walker.perform("open-drawer", arrivesAt: .drawer)
		let account = try await walker.perform("open-account", arrivesAt: .account)
		XCTAssertEqual(account.state.value(at: "/signedIn"), .bool(false), "[walk fresh]")
		try await walker.perform("close", arrivesAt: .drawer)
		try await walker.perform("open-findings", arrivesAt: .findings)
		try await walker.perform("close", arrivesAt: .drawer)
		try await walker.perform("close", arrivesAt: .home)

		let detected = try await walker.perform("detect-image", ["image": "walk.png"], arrivesAt: .home)
		XCTAssertEqual(detected.result?.value(at: "/detections/0/label"), .string("walk-object"), "[walk fresh]")
		try await walker.perform("pick", ["detection": 0], arrivesAt: .saveFinding)
		// Never `save`: see the class comment.
		try await walker.perform("cancel", arrivesAt: .home)
		return walker.visited
	}

	/// A validated account: launching → welcome → tour → home → drawer → account → sign-out → drawer.
	private func walkASignedInAccount() async throws -> Set<HeadlessRoute> {
		let walker = try await makeWalker(
			name: "signed-in",
			auth: MockAuthProvider(outcome: .ready, accountID: "user_walk000000000000000000")
		)
		try await walker.observe(expecting: .launching)
		walker.ready.isReady = true
		try await walker.settle(at: .welcome)
		try await walker.perform("continue", arrivesAt: .tour)
		try await walker.perform("skip", arrivesAt: .home)
		try await walker.perform("open-drawer", arrivesAt: .drawer)
		let account = try await walker.perform("open-account", arrivesAt: .account)
		XCTAssertEqual(account.state.value(at: "/signedIn"), .bool(true), "[walk signed-in]")
		let signedOut = try await walker.perform("sign-out", arrivesAt: .drawer)
		XCTAssertEqual(signedOut.context.value(at: "/auth/signedIn"), .bool(false), "[walk signed-in]")
		return walker.visited
	}

	/// Payments on, no free-access window, not subscribed: launching → paywall; a subscription
	/// arriving (Ask to Buy approved) → tour.
	private func walkTheWall() async throws -> Set<HeadlessRoute> {
		let walker = try await makeWalker(
			name: "wall",
			auth: MockAuthProvider(outcome: .signedOut),
			isFreeAccessPeriodEnabled: false
		)
		try await walker.observe(expecting: .launching)
		walker.ready.isReady = true
		let paywall = try await walker.settle(at: .paywall)
		XCTAssertTrue(paywall.actions.isEmpty, "[walk wall] the wall offers nothing")

		walker.world.provider.simulateEntitlementChange(to: .subscribed)
		try await walker.settle(at: .tour)
		return walker.visited
	}

	/// The free-access window runs out while the account screen is up: the sheet stays above the
	/// paywall laid over the app, closing it lands on the paywall, and a subscription then uncovers
	/// the open menu.
	private func walkAccessRunningOutUnderASheet() async throws -> Set<HeadlessRoute> {
		let walker = try await makeWalker(name: "expiry", auth: MockAuthProvider(outcome: .signedOut))
		try await walker.observe(expecting: .launching)
		walker.ready.isReady = true
		try await walker.settle(at: .welcome)
		try await walker.perform("continue", arrivesAt: .tour)
		try await walker.perform("skip", arrivesAt: .home)
		try await walker.perform("open-drawer", arrivesAt: .drawer)
		try await walker.perform("open-account", arrivesAt: .account)

		let world = walker.world
		world.clock.now = try XCTUnwrap(GateWorld.calendar.date(byAdding: .day, value: 16, to: world.clock.now))
		world.foreground()
		let ranOut = try await HeadlessWait.until(timeout: .seconds(10)) {
			walker.application.currentDecision().display == .wallOverContent
		}
		XCTAssertTrue(ranOut, "[walk expiry] the window did not run out")
		try await walker.observe(expecting: .account)

		try await walker.perform("close", arrivesAt: .paywall)
		world.provider.simulateEntitlementChange(to: .subscribed)
		try await walker.settle(at: .drawer)
		return walker.visited
	}

	/// Payments off: launching → welcome (the introduction) → tour → home.
	private func walkPaymentsOff() async throws -> Set<HeadlessRoute> {
		let walker = try await makeWalker(
			name: "payments-off",
			auth: MockAuthProvider(outcome: .signedOut),
			isPaymentsEnabled: false
		)
		try await walker.observe(expecting: .launching)
		walker.ready.isReady = true
		let welcome = try await walker.settle(at: .welcome)
		XCTAssertEqual(welcome.state.value(at: "/offer"), .string("introduction"), "[walk payments-off]")
		try await walker.perform("continue", arrivesAt: .tour)
		try await walker.perform("skip", arrivesAt: .home)
		return walker.visited
	}

	// MARK: - Building a world

	/// A real headless application on isolated parts, with a gate world built as the app builds it.
	private func makeWalker(
		name: String,
		auth provider: MockAuthProvider,
		isPaymentsEnabled: Bool = true,
		isFreeAccessPeriodEnabled: Bool = true,
		startFreeAccess: Bool = true,
		answersConsent: Bool = true
	) async throws -> Walker {
		let root = scratch.appending(path: name, directoryHint: .isDirectory)
		let stagedDirectory = root.appending(path: "Staged", directoryHint: .isDirectory)
		let findingsDirectory = root.appending(path: "Findings", directoryHint: .isDirectory)
		let ledgerDirectory = root.appending(path: "Ledger", directoryHint: .isDirectory)
		for directory in [stagedDirectory, findingsDirectory, ledgerDirectory] {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		try Self.stageImage(named: "walk.png", in: stagedDirectory)

		let suiteName = "com.aiarcheology.ios.tests.headlessWalk.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
		let world = try await makeGateWorld(
			defaults: defaults,
			isPaymentsEnabled: isPaymentsEnabled,
			isFreeAccessPeriodEnabled: isFreeAccessPeriodEnabled,
			startFreeAccess: startFreeAccess,
			answersConsent: answersConsent
		)

		let dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		let settings = Settings()
		let deep = DeepState(dataController: dataController)
		deep.drivers.register(
			driver: FixedObjectsDetecting(
				params: DeepDriverParams(entityId: UUID(), modelName: "Stub"),
				objects: [
					DetectedObject(
						uuid: UUID(),
						labels: [DetectedObject.Label(identifier: "walk-object", confidence: 0.9)],
						confidence: 0.8,
						boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
						regionIndex: 0
					)
				]
			),
			along: .detector
		)
		let repository = FindingRepository(dataController: dataController)
		let findingsSync = FindingsSyncCoordinator(
			authProvider: provider,
			analytics: world.analytics,
			findingRepository: repository,
			dataController: dataController,
			transportFactory: { url in
				FindingsCloudTransport(baseURL: url, session: StubWorkerProtocol.session) { "stub.token" }
			},
			ledgerDirectory: ledgerDirectory
		)
		let authState = AuthState(provider: provider)
		await authState.start()

		let snap = SnapState(settings: settings)
		addTeardownBlock { @MainActor in snap.stopTimer() }
		let chromeState = AppChromeState(
			detectionState: DetectionSessionState(snap: snap, settings: settings, snapAdjustment: SnapAdjustment()),
			deep: deep,
			settings: settings,
			demoDataManager: DemoDataManager(dataController: dataController)
		)

		let ready = ReadyFlag()
		let parts = HeadlessAppParts(
			analytics: world.analytics,
			authState: authState,
			chromeState: chromeState,
			dataController: dataController,
			deep: deep,
			findingRepository: repository,
			findingsSync: findingsSync,
			freeAccess: world.freeAccess,
			settings: settings,
			subscriptionState: world.subscriptionState,
			tour: world.tour,
			isReady: { ready.isReady },
			usesRealAuth: false,
			stagedNames: ["walk.png"],
			stagedDirectory: stagedDirectory,
			findingsDirectory: findingsDirectory
		)
		// The walk writes only where it was pointed.
		XCTAssertEqual(parts.stagedDirectory, stagedDirectory, "[walk \(name)]")
		XCTAssertNotEqual(parts.stagedDirectory, StagedImageCapture.defaultStagedDirectory, "[walk \(name)]")
		XCTAssertEqual(parts.findingsDirectory, findingsDirectory, "[walk \(name)]")
		XCTAssertNotEqual(parts.findingsDirectory, FindingScreenshotStore.directory, "[walk \(name)]")

		let application = MLBrowserHeadlessApplication(parts: parts, launchOptions: .object([:]))
		return Walker(name: name, application: application, world: world, ready: ready)
	}

	/// Writes a real 10×10 PNG.
	private static func stageImage(named name: String, in directory: URL) throws {
		let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
			UIColor.gray.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
		}
		let data = try XCTUnwrap(image.pngData())
		try data.write(to: directory.appending(path: name))
	}

	/// The app's own screenshot and staging directories: their listings, or `nil` where absent.
	private static func realDirectoryListings() -> [String: [String]?] {
		let directories = [FindingScreenshotStore.directory, StagedImageCapture.defaultStagedDirectory].compactMap { $0 }
		var listings: [String: [String]?] = [:]
		for directory in directories {
			let listing = try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
			listings[directory.path] = .some(listing)
		}
		return listings
	}
}

// MARK: - The walker

/// `AppState.isReady`, owned by the test.
@MainActor
private final class ReadyFlag {
	var isReady = false
}

/// Drives one application through `InProcessDriver` and checks every state and move against the map.
@MainActor
private final class Walker {
	/// The walk's name, which every failure message starts with.
	let name: String
	let application: MLBrowserHeadlessApplication
	let world: GateWorld
	let ready: ReadyFlag
	private let driver: InProcessDriver
	private let map = HeadlessNavigationMap.declaration
	private(set) var visited: Set<HeadlessRoute> = []
	/// The route of the last observed state.
	private var current: HeadlessRoute?

	/// Upper bound for the app to move on its own; the moves are immediate once their input changes.
	private static let settleTimeout = 10.0

	init(name: String, application: MLBrowserHeadlessApplication, world: GateWorld, ready: ReadyFlag) {
		self.name = name
		self.application = application
		self.world = world
		self.ready = ready
		driver = InProcessDriver(session: HeadlessSession(application: application))
	}

	/// Looks at the current state: it must be `expected`, satisfy the reachable-state predicate once
	/// the app is ready, and offer no transition the map lacks.
	@discardableResult
	func observe(
		expecting expected: HeadlessRoute,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> Response {
		let response = try await driver.send(.map)
		XCTAssertTrue(response.ok, "[walk \(name)] map failed: \(String(describing: response.error))", file: file, line: line)
		let route = try XCTUnwrap(
			HeadlessRoute(rawValue: response.route.rawValue),
			"[walk \(name)] '\(response.route)' is not a route",
			file: file,
			line: line
		)
		XCTAssertEqual(route, expected, "[walk \(name)]", file: file, line: line)
		visited.insert(route)
		current = route

		// The drift check: every offered action that declares a destination is a declared edge.
		XCTAssertEqual(
			response.result?.value(at: "/undeclared"),
			.array([]),
			"[walk \(name)] '\(route.rawValue)' offers transitions the navigation map lacks",
			file: file,
			line: line
		)

		let decision = application.currentDecision()
		XCTAssertEqual(decision.route, route, "[walk \(name)]", file: file, line: line)
		if decision.isReady, let violation = HeadlessReachableStates.violation(of: decision) {
			XCTFail("[walk \(name)] the walk reached a state the enumeration calls unreachable (\(violation)): \(decision)", file: file, line: line)
		}
		return response
	}

	/// Performs `action`; it must succeed and arrive at `expected`, and a move to another route must
	/// be a declared (from, action, to) edge. An action that stays on its route is a self-loop, which
	/// the map does not declare.
	@discardableResult
	func perform(
		_ action: String,
		_ arguments: [String: JSONValue] = [:],
		arrivesAt expected: HeadlessRoute,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> Response {
		let from = try XCTUnwrap(current, "[walk \(name)] observe before performing", file: file, line: line)
		let response = try await driver.send(.perform(action: action, arguments: arguments))
		XCTAssertTrue(response.ok, "[walk \(name)] '\(action)' failed: \(String(describing: response.error))", file: file, line: line)
		XCTAssertEqual(response.route.rawValue, expected.rawValue, "[walk \(name)] '\(action)' on '\(from.rawValue)'", file: file, line: line)
		if expected != from {
			XCTAssertTrue(
				map.declares(action: action, from: Route(from.rawValue), to: Route(expected.rawValue)),
				"[walk \(name)] undeclared edge: \(from.rawValue) --\(action)--> \(expected.rawValue)",
				file: file,
				line: line
			)
		}
		try await observe(expecting: expected, file: file, line: line)
		return response
	}

	/// Waits, as a client does, for the app to move to `expected` on its own; the move must be a
	/// declared action-less edge.
	@discardableResult
	func settle(at expected: HeadlessRoute, file: StaticString = #filePath, line: UInt = #line) async throws -> Response {
		let from = try XCTUnwrap(current, "[walk \(name)] observe before settling", file: file, line: line)
		let response = try await driver.send(.wait(
			condition: HeadlessSession.routeCondition,
			arguments: ["route": .string(expected.rawValue)],
			timeout: Self.settleTimeout
		))
		XCTAssertTrue(response.ok, "[walk \(name)] the app did not move to '\(expected.rawValue)': \(String(describing: response.error))", file: file, line: line)
		if expected != from {
			let declared = map.declaration(for: Route(from.rawValue))?.transitions
				.contains { $0.action == nil && $0.to.rawValue == expected.rawValue } ?? false
			XCTAssertTrue(declared, "[walk \(name)] undeclared move on its own: \(from.rawValue) --> \(expected.rawValue)", file: file, line: line)
		}
		return try await observe(expecting: expected, file: file, line: line)
	}
}
