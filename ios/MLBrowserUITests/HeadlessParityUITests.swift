//
//  HeadlessParityUITests.swift
//  MLBrowserUITests
//
//  AIA-0984: the UI leg of the headless parity check.
//

import XCTest

/// Drives the app through the four flows of the `parity-*` headless scenarios and checks that the
/// screens it lands on are the routes those scenarios expect (AIA-0984).
///
/// Each test reads its scenario from this bundle, so the expected sequence has one source: the file
/// the headless leg runs. A list of step closures matches the scenario's steps one to one and performs
/// the gestures for each; a closure for a `wait route` step implements that `wait` command itself,
/// polling until the named route is on top within the step's timeout, as the headless leg does. After
/// every step that carries a `route` expectation, the recorder notes the screen on top. The recorder
/// never knows the expected route and orders no overlay or sheet above another: it waits for the hittable screen probes to name one screen and to stay so, counting the
/// app proper only when nothing covers it. The recorded list is compared with the scenario's list
/// once, at the end.
///
/// Not part of `MLBrowserUITests.xctestplan`; run it with `-testPlan HeadlessParity`. The sign-in
/// flow signs the scenario's automation account in on Clerk's development instance, so it must not
/// run at the same time as a headless scenario that uses that account.
final class HeadlessParityUITests: UITestCase {

	// MARK: Probes

	/// The elements that say a route is on top when one of them is hittable, keyed by the route as the
	/// scenarios spell it.
	private static let probes: [String: [String]] = [
		"welcome": [AID.welcomeContent],
		"tour": [AID.tourBubble],
		"consent": [AID.analyticsChoiceNotNow],
		// The web toolbar's menu button; as the app proper it counts only when nothing covers it.
		"home": [AID.cpu],
		"drawer": [AID.drawerSettings],
		// The drawer's sign-in sheet and the offer after a save are both `SignInSheet`. Signed in, the
		// account row opens Settings straight onto Clerk's profile, whose first row is Manage account.
		"account": [AID.signInSheetCancel, AID.settingsDismiss, manageAccountRow],
		"findings": [AID.findingsDismiss],
		"save-finding": [AID.saveFindingSave],
		"paywall": [AID.paywallContent],
		"backup-consent": [AID.backupConsentConfirm]
	]

	/// The app proper: the layer every overlay and sheet sits above (see ``topmost(of:)``).
	private static let baseRoutes: Set<String> = ["home", "drawer"]

	/// How long the single hittable probe must stay the same before it is recorded.
	private static let settleInterval: TimeInterval = 1.5

	/// The recorder's bound for a step with no `wait.timeout` of its own.
	private static let defaultStepTimeout: TimeInterval = 20

	private static let signOutRow = "clerk.userProfile.row.signOut"
	private static let manageAccountRow = "clerk.userProfile.row.manageAccount"

	private var launchedAt = Date()
	private var lastRecorded: String?
	/// Set by the sign-in flow, so a run that failed mid-way still leaves the Clerk session signed out.
	private var signsOutOnTearDown = false

	override func tearDown() async throws {
		if signsOutOnTearDown {
			signOutBestEffort()
		}
		try await super.tearDown()
	}

	// MARK: Flows

	func test_onboarding() throws {
		let scenario = try loadScenario("parity-onboarding")
		launchApp(for: scenario)
		run(scenario, steps: [
			{ _ in },
			{ _ in self.tap(AID.welcomeContinue) },
			{ _ in self.tap(AID.tourSkip) },
			{ _ in self.tap(AID.analyticsChoiceNotNow) }
		])
	}

	func test_signInAndSignOut() throws {
		let scenario = try loadScenario("parity-sign-in")
		signsOutOnTearDown = true
		launchApp(for: scenario, usesRealAuth: true)
		run(scenario, steps: [
			{ _ in },
			{ _ in self.tap(AID.welcomeContinue) },
			{ _ in self.tap(AID.tourSkip) },
			{ _ in self.tap(AID.analyticsChoiceNotNow) },
			{ _ in self.tap(AID.cpu) },
			{ _ in self.openAccount() },
			{ step in self.signInThroughClerk(step) },
			{ step in self.waitForRoute(step) },
			{ _ in self.tap(AID.analyticsChoiceNotNow) },
			{ _ in self.openAccount() },
			{ _ in self.signOutThroughClerk() }
		])
	}

	func test_saveFinding() throws {
		let scenario = try loadScenario("parity-save-finding")
		launchApp(for: scenario, loadsLocalFixture: true)
		run(scenario, steps: [
			{ _ in },
			{ _ in self.tap(AID.welcomeContinue) },
			{ _ in self.tap(AID.tourSkip) },
			{ _ in self.tap(AID.analyticsChoiceNotNow) },
			{ _ in self.tap(AID.cpu) },
			{ _ in self.enableFirstModel() },
			{ _ in self.closeDrawer() },
			{ _ in self.waitForDetectionFrame() },
			{ _ in self.pickUnderCrosshair() },
			{ step in self.saveFinding(step) },
			{ _ in self.tap(AID.signInSheetCancel) }
		])
	}

	func test_paywallOverOpenFindings() throws {
		let scenario = try loadScenario("parity-paywall-over-sheet")
		let endsIn = try XCTUnwrap(scenario.freeAccessEndsIn, "the paywall flow needs launch.freeAccessEndsIn")
		launchApp(for: scenario)
		run(scenario, steps: [
			{ _ in },
			{ _ in self.tap(AID.tourSkip) },
			{ _ in self.tap(AID.analyticsChoiceNotNow) },
			{ _ in self.tap(AID.cpu) },
			{ _ in self.tap(AID.drawerFindings) },
			{ _ in self.waitForExpiry(endsIn: endsIn) },
			{ _ in self.tap(AID.findingsDismiss) }
		])
	}

	// MARK: Scenario

	private struct Scenario {
		let name: String
		let flags: [String: Bool]
		let freeAccessEndsIn: Int?
		let steps: [Step]
	}

	private struct Step {
		/// The step's number, kind and name, for failure messages.
		let label: String
		let arguments: [String: Any]
		let waitTimeout: TimeInterval?
		/// The route a `wait` step with `condition: route` waits for (its `wait.arguments.route`).
		let waitRoute: String?
		/// The step's `route` expectation, when it carries one.
		let route: String?
	}

	/// Reads `<name>.json` from the UI-test bundle: its single installation's launch block and, per
	/// step, the `route` expectation, the `wait` timeout and route, and the `perform` arguments.
	private func loadScenario(_ name: String) throws -> Scenario {
		let bundle = Bundle(for: HeadlessParityUITests.self)
		let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "\(name).json is not in the UI-test bundle")
		let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(name).json is not an object")
		let installations = try XCTUnwrap(root["installations"] as? [String: Any], "\(name).json has no installations")
		XCTAssertEqual(installations.count, 1, "\(name).json: the UI leg drives one installation")
		let installation = try XCTUnwrap(installations.values.first as? [String: Any])
		let launch = installation["launch"] as? [String: Any] ?? [:]
		let rawSteps = try XCTUnwrap(root["steps"] as? [[String: Any]], "\(name).json has no steps")

		var steps: [Step] = []
		for (index, raw) in rawSteps.enumerated() {
			let perform = raw["perform"] as? [String: Any]
			let wait = raw["wait"] as? [String: Any]
			let routes = (raw["expect"] as? [[String: Any]] ?? []).compactMap { $0["route"] as? String }
			XCTAssertLessThanOrEqual(routes.count, 1, "\(name).json step \(index + 1) carries more than one route expectation")
			let kind = (raw["goto"] as? String).map { "goto \($0)" }
				?? (perform?["action"] as? String).map { "perform \($0)" }
				?? (wait?["condition"] as? String).map { "wait \($0)" }
				?? "observe"
			steps.append(Step(
				label: "\(index + 1). \(kind)" + ((raw["name"] as? String).map { " (\($0))" } ?? ""),
				arguments: perform?["arguments"] as? [String: Any] ?? [:],
				waitTimeout: (wait?["timeout"] as? NSNumber)?.doubleValue,
				waitRoute: wait?["condition"] as? String == "route"
					? (wait?["arguments"] as? [String: Any])?["route"] as? String
					: nil,
				route: routes.first
			))
		}
		return Scenario(
			name: name,
			flags: launch["flags"] as? [String: Bool] ?? [:],
			freeAccessEndsIn: (launch["freeAccessEndsIn"] as? NSNumber)?.intValue,
			steps: steps
		)
	}

	/// The scenario's launch, mapped onto the UI-test launch configuration: its flags, the tour armed,
	/// the analytics question unanswered, no subscription, and signed out (mock auth) unless the flow
	/// signs in for real.
	private func launchApp(for scenario: Scenario, usesRealAuth: Bool = false, loadsLocalFixture: Bool = false) {
		var config = LaunchConfig()
		config.featureFlagOverrides = scenario.flags
		config.startOnboardingTour = true
		config.analyticsScenario = .prompt
		config.freeAccessEndsInSeconds = scenario.freeAccessEndsIn
		if usesRealAuth {
			config.usesRealAuth = true
		}
		if loadsLocalFixture {
			config.pageScenario = .localFixture
			config.fixtureName = "uitest_page"
		}
		launch(config, mockAuthGate: usesRealAuth ? nil : "signedOut", mockSubscription: "notSubscribed")
		// After `launch` returns: the app seeds the window during its own init, before that, so the
		// window ends no later than `launchedAt + freeAccessEndsIn`.
		launchedAt = Date()
	}

	/// Runs the closures, one per scenario step, recording the topmost route after each step that
	/// carries one, then compares the recorded list with the scenario's. A closure runs its step's
	/// gestures, or for a `wait route` step the wait itself (``waitForRoute(_:)``).
	private func run(_ scenario: Scenario, steps closures: [(Step) -> Void]) {
		guard closures.count == scenario.steps.count else {
			return XCTFail("\(scenario.name): \(closures.count) step closures for \(scenario.steps.count) scenario steps")
		}
		let unprobed = Set(scenario.steps.compactMap(\.route)).filter { Self.probes[$0] == nil }
		guard unprobed.isEmpty else {
			return XCTFail("\(scenario.name) visits routes with no screen probe: \(unprobed.sorted())")
		}

		var expected: [String] = []
		var recorded: [String] = []
		var labels: [String] = []
		for (step, perform) in zip(scenario.steps, closures) {
			perform(step)
			guard let route = step.route else { continue }
			let topmost = recordTopmost(for: step)
			expected.append(route)
			recorded.append(topmost)
			labels.append(step.label)
			lastRecorded = topmost
		}

		if recorded != expected {
			// What the final screen looked like and what XCUITest could see of it.
			let screenshot = XCTAttachment(screenshot: app.screenshot())
			screenshot.name = "\(scenario.name) final screen"
			screenshot.lifetime = .keepAlways
			add(screenshot)
			print("PARITY \(scenario.name) final tree:\n\(app.debugDescription)")
			let rows = zip(labels, zip(expected, recorded)).map { label, pair in
				"\(pair.0 == pair.1 ? " " : "✗") \(label): expected \(pair.0), recorded \(pair.1)"
			}
			XCTFail("""
				\(scenario.name): the UI's screens differ from the scenario's routes
				scenario: \(expected)
				UI:       \(recorded)
				\(rows.joined(separator: "\n"))
				""")
		}
	}

	// MARK: Recorder

	/// The route on top once it has settled: the set of hittable probes names one screen
	/// (``topmost(of:)``) and stays the same for ``settleInterval``, within the step's `wait.timeout` or
	/// ``defaultStepTimeout``. A set that names no single screen at the deadline fails the step,
	/// naming what was hittable.
	private func recordTopmost(for step: Step) -> String {
		let timeout = step.waitTimeout ?? Self.defaultStepTimeout
		let deadline = Date().addingTimeInterval(timeout)
		var candidate: Set<String>?
		var since = Date()
		var table = ""
		while true {
			let sample = hittableRoutes()
			table = sample.table
			let now = Date()
			if sample.routes != candidate {
				candidate = sample.routes
				since = now
			} else if let route = Self.topmost(of: sample.routes),
					  now.timeIntervalSince(since) >= Self.settleInterval {
				print("PARITY \(step.label): recorded \(route)")
				return route
			}
			if now >= deadline { break }
			Thread.sleep(forTimeInterval: 0.25)
		}
		let routes = (candidate ?? []).sorted()
		let described = routes.isEmpty ? "<none>" : "<several: \(routes.joined(separator: ", "))>"
		print("PARITY \(step.label): recorded \(described)\n\(table)")
		XCTFail("\(step.label): no single screen on top after \(Int(timeout)) s; hittable probes: \(described)\n\(table)")
		return described
	}

	/// The one screen a set of hittable probes names, or `nil` when it names none or several.
	///
	/// Two tiers, and only two. The app proper (``baseRoutes``: home, or the drawer) is beneath every
	/// overlay and every sheet by construction: the Welcome screen and the paywall are overlays on the
	/// root gate's content, the consent card on the analytics gate's, the tour on `ContentView`, the
	/// back-up card at the scene root, and sheets are presented above all of them. Not every overlay
	/// hides what it covers from XCUITest, so the app proper can stay hittable beneath one; this rule
	/// discounts it while any other probe is hittable. That is all it encodes. Among the overlays and
	/// sheets there is no order: two of them hittable at once names no screen and fails, so the test
	/// still checks the stacking it exists for (a sheet against the paywall, the back-up question, the
	/// consent card, the Welcome screen or the tour).
	private static func topmost(of routes: Set<String>) -> String? {
		let covering = routes.subtracting(baseRoutes)
		if covering.isEmpty {
			return routes.count == 1 ? routes.first : nil
		}
		return covering.count == 1 ? covering.first : nil
	}

	/// The routes whose probe is hittable now, and a table of every probe that exists.
	///
	/// Each probe is queried on its own. A whole-app `snapshot()` is no shortcut: with the drawer open
	/// it leaves out everything outside the drawer's `.isModal` panel, the paywall laid over it
	/// included, although a query finds that paywall and reports it hittable.
	private func hittableRoutes() -> (routes: Set<String>, table: String) {
		var routes = Set<String>()
		var rows: [String] = []
		for (route, ids) in Self.probes.sorted(by: { $0.key < $1.key }) {
			for id in ids {
				let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
				let exists = element.exists
				let hittable = exists && element.isHittable
				if exists { rows.append("  \(hittable ? "H" : "-") \(route): \(id)") }
				if hittable { routes.insert(route) }
			}
		}
		return (routes, rows.joined(separator: "\n"))
	}

	// MARK: Gestures

	private func tap(_ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
		let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
		guard waitForHittable(element, timeout: timeout) else {
			return XCTFail("\(id) never became hittable", file: file, line: line)
		}
		element.tap()
	}

	private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
		let predicate = NSPredicate(format: "exists == true && hittable == true")
		let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
		return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
	}

	/// The scenario's `wait route <route>` command: within the step's timeout, that route is on top.
	/// Polls until it is, or until the deadline; either way it returns without a verdict, and the
	/// recorder that follows settles and names what it finds.
	private func waitForRoute(_ step: Step) {
		guard let route = step.waitRoute else { return XCTFail("\(step.label) is not a `wait route` step") }
		let deadline = Date().addingTimeInterval(step.waitTimeout ?? Self.defaultStepTimeout)
		while Date() < deadline {
			if Self.topmost(of: hittableRoutes().routes) == route { return }
			Thread.sleep(forTimeInterval: 0.25)
		}
	}

	/// Until one route other than `previous` is on top, bounded. The recorder that follows settles
	/// and names what it finds.
	private func waitForTopmostToLeave(_ previous: String?, timeout: TimeInterval) {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if let route = Self.topmost(of: hittableRoutes().routes), route != previous { return }
			Thread.sleep(forTimeInterval: 0.25)
		}
	}

	/// The drawer footer's account row: Sign In while signed out, the account once signed in.
	private func openAccount() {
		let signedIn = app.buttons[AID.drawerAccount]
		let signedOut = app.buttons[AID.drawerSignIn]
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline {
			if signedIn.exists, signedIn.isHittable { return signedIn.tap() }
			if signedOut.exists, signedOut.isHittable { return signedOut.tap() }
			Thread.sleep(forTimeInterval: 0.25)
		}
		XCTFail("The drawer offered neither its account row nor Sign In")
	}

	/// Clerk's `AuthView`, from the sign-in sheet: the address, then an emailed code (the automation
	/// account lands on its password screen first, so the code is chosen as another method).
	private func signInThroughClerk(_ step: Step) {
		guard let email = step.arguments["email"] as? String, let code = step.arguments["code"] as? String else {
			return XCTFail("\(step.label) names no email and code")
		}
		tap(AID.authSignIn)
		let identifier = element("clerk.auth.start.identifier").firstMatch
		guard identifier.waitForExistence(timeout: 30) else { return XCTFail("Clerk's address field never appeared") }
		identifier.tap()
		Thread.sleep(forTimeInterval: 1)
		// The visible element is the field's placeholder; the keyboard focus is the real field.
		app.typeText(email)
		element("clerk.auth.start.continue").firstMatch.tap()

		let codeField = element("clerk.auth.signIn.code").firstMatch
		let password = element("clerk.auth.signIn.password").firstMatch
		let deadline = Date().addingTimeInterval(30)
		while Date() < deadline, codeField.exists == false, password.exists == false {
			Thread.sleep(forTimeInterval: 0.5)
		}
		if password.exists, codeField.exists == false {
			element("clerk.auth.signIn.useAnotherMethod").firstMatch.tap()
			let emailCode = element("clerk.auth.signIn.alternativeMethod.email_code").firstMatch
			guard emailCode.waitForExistence(timeout: 10) else { return XCTFail("Clerk offered no emailed code") }
			emailCode.tap()
		}
		guard codeField.waitForExistence(timeout: 20) else { return XCTFail("Clerk's code field never appeared") }
		codeField.tap()
		Thread.sleep(forTimeInterval: 1)
		// A complete code submits itself.
		app.typeText(code)
	}

	/// Sign Out in Clerk's profile, which Settings opens onto; Settings closes itself afterwards, once
	/// Clerk's sign-out request has returned, so this waits (bounded) for the account screen to leave
	/// the top.
	private func signOutThroughClerk() {
		let row = element(Self.signOutRow).firstMatch
		guard row.waitForExistence(timeout: 20) else { return XCTFail("Clerk's profile offered no Sign Out") }
		if row.isHittable == false {
			app.swipeUp()
		}
		row.tap()
		waitForTopmostToLeave(lastRecorded, timeout: 30)
	}

	/// Leaves the automation account signed out after a run that stopped part-way. Best effort: no
	/// assertion, and nothing is tapped that is not there.
	private func signOutBestEffort() {
		guard let app, app.state == .runningForeground else { return }
		let row = element(Self.signOutRow).firstMatch
		if row.exists == false {
			for id in [AID.analyticsChoiceNotNow, AID.signInSheetCancel, AID.findingsDismiss] {
				let element = app.buttons[id]
				if element.exists, element.isHittable { element.tap() }
			}
			let account = app.buttons[AID.drawerAccount]
			if account.exists == false {
				let menu = app.buttons[AID.cpu]
				if menu.exists, menu.isHittable { menu.tap() }
			}
			guard account.waitForExistence(timeout: 5), account.isHittable else { return }
			account.tap()
			guard row.waitForExistence(timeout: 20) else { return }
		}
		if row.isHittable == false {
			app.swipeUp()
		}
		if row.isHittable {
			row.tap()
		}
	}

	private func enableFirstModel() {
		XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")
		XCTAssertTrue(flipSwitch(AID.configEnabledToggle), "The first model's switch did not change")
	}

	/// Taps the scrim beside the 300 pt drawer panel, which closes it.
	private func closeDrawer() {
		let window = app.windows.firstMatch.frame
		app.windows.firstMatch
			.coordinate(withNormalizedOffset: .zero)
			.withOffset(CGVector(dx: window.width - 20, dy: window.height / 2))
			.tap()
	}

	/// The UI's stand-in for `detect-image`: detection runs on the live page, so give it a bounded
	/// chance to apply a frame. The red crosshair stores a finding without one, so none is required.
	private func waitForDetectionFrame() {
		let applied = waitForCheckpoint(AID.cpDetectionFrameApplied, equals: "true", timeout: 15)
		print("PARITY detection frame applied: \(applied)")
	}

	/// Find, then a tap on the crosshair: the finding form opens whether the crosshair is red or green.
	private func pickUnderCrosshair() {
		XCTAssertTrue(
			waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
			"Local fixture did not become the live page"
		)
		tap(AID.findTop)
		let crosshair = element(AID.findingAlignmentCrosshair)
		guard crosshair.waitForExistence(timeout: 10) else { return XCTFail("Find did not show the crosshair") }
		// The target is circular; tap its centre, not XCTest's hit point (see NavigationUITests).
		crosshair.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
	}

	/// Save needs a title; the scenario's is typed when the form has none.
	private func saveFinding(_ step: Step) {
		let save = app.buttons[AID.saveFindingSave]
		guard save.waitForExistence(timeout: 15) else { return XCTFail("The finding form offered no Save") }
		if save.isEnabled == false {
			let title = app.textFields[AID.saveFindingTitle]
			title.tap()
			title.typeText(step.arguments["title"] as? String ?? "Parity save")
		}
		tap(AID.saveFindingSave)
	}

	/// `access-ended`: the window was seeded to end `endsIn` seconds after launch, so wait until then
	/// plus slack. A paywall already on top means it ended before the flow reached this step.
	private func waitForExpiry(endsIn: Int) {
		if Self.topmost(of: hittableRoutes().routes) == "paywall" {
			return XCTFail("expiry fired too early; raise freeAccessEndsIn")
		}
		let remaining = launchedAt.addingTimeInterval(TimeInterval(endsIn) + 10).timeIntervalSinceNow
		if remaining > 0 {
			Thread.sleep(forTimeInterval: remaining)
		}
	}
}
