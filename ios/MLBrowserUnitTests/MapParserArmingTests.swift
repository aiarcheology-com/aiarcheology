//
//  MapParserArmingTests.swift
//  MLBrowserUnitTests
//
//  AIA-0821: the parser must not be able to cost the user the page.
//

import WebKit
import XCTest
@testable import ML_Browser

@MainActor
final class MapParserArmingTests: XCTestCase {

	private var settings: Settings!
	private var arming: MapParserArming!
	/// What the simulator's defaults held before this test ran — including *nothing*.
	///
	/// The unit suite resolves `Settings` to `UserDefaults.standard`, which outlives the test
	/// process. Forcing the value to `true` in tearDown looked like restoration and was not: it
	/// destroyed a real `false` and turned an absent key into a persisted `true`, which is the
	/// reset-surviving-state failure class this project has been bitten by before (raised in review).
	private var originalSetting: Bool?

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		originalSetting = UserDefaults.standard.object(forKey: "readMapPositionFromPages") as? Bool
		settings.readMapPositionFromPages = true
		arming = MapParserArming(settings: settings)
	}

	override func tearDown() async throws {
		Self.restore(originalSetting, on: settings)
		settings = nil
		arming = nil
		try await super.tearDown()
	}

	/// Puts the persisted value back exactly as it was, removing the key when there was none.
	static func restore(_ original: Bool?, on settings: Settings?) {
		if let original {
			settings?.readMapPositionFromPages = original
		} else {
			settings?.readMapPositionFromPages = true
			UserDefaults.standard.removeObject(forKey: "readMapPositionFromPages")
		}
	}

	private let page = URL(string: "https://maps.example.org/viewer?x=1")

	// MARK: - The three ways to be disarmed

	func testIsArmed_ByDefault_IsArmed() {
		XCTAssertTrue(arming.isArmed(for: page))
	}

	func testIsArmed_UserSwitchOff_IsDisarmed() {
		settings.readMapPositionFromPages = false
		XCTAssertFalse(
			arming.isArmed(for: page),
			"the Settings switch is the only kill switch a user can reach; if it does not disarm, it is decoration"
		)
	}

	func testIsArmed_AfterTheHostTripped_IsDisarmed() {
		arming.recordFailure(host: "maps.example.org")
		XCTAssertFalse(arming.isArmed(for: page))
	}

	func testIsArmed_AnotherHost_IsUnaffectedByATrip() {
		arming.recordFailure(host: "maps.example.org")
		XCTAssertTrue(
			arming.isArmed(for: URL(string: "https://other.example.net/")),
			"one site breaking must not cost the feature everywhere"
		)
	}

	// MARK: - Host keys

	func testIsArmed_HostCase_IsIgnored() {
		arming.recordFailure(host: "MAPS.Example.ORG")
		XCTAssertFalse(
			arming.isArmed(for: page),
			"a host recorded in one casing must match the same host in another"
		)
	}

	func testIsArmed_SubdomainIsNotTheSameHost() {
		arming.recordFailure(host: "maps.example.org")
		XCTAssertTrue(
			arming.isArmed(for: URL(string: "https://www.maps.example.org/")),
			"only the host that was observed failing is suppressed; nothing is normalised beyond case"
		)
	}

	func testIsArmed_URLWithNoHost_IsArmed() {
		XCTAssertTrue(
			arming.isArmed(for: URL(string: "about:blank")),
			"a URL with no host cannot be tripped, and the file-based harness pages depend on staying armed"
		)
	}

	// MARK: - The one reload per host

	func testRecordFailure_FirstTripForAHost_AllowsTheReload() {
		XCTAssertTrue(arming.recordFailure(host: "maps.example.org"))
	}

	func testRecordFailure_SecondTripForTheSameHost_RefusesTheReload() {
		XCTAssertTrue(arming.recordFailure(host: "maps.example.org"))
		XCTAssertFalse(
			arming.recordFailure(host: "maps.example.org"),
			"a second automatic reload for the same host is how an auto-reload becomes a loop"
		)
	}

	func testRecordFailure_NoHost_RecordsNothingAndRefusesTheReload() {
		XCTAssertFalse(arming.recordFailure(host: nil))
		XCTAssertFalse(arming.hasTripped(host: nil))
	}

	// MARK: - The trip condition

	func testShouldDisarm_ErrorsAndBlankOnAnArmedDocument_Trips() {
		XCTAssertTrue(
			MapParserArming.shouldDisarm(armedForDocument: true, mainFrameErrors: 1, renderedNothing: true)
		)
	}

	func testShouldDisarm_ErrorsWithoutBlankness_DoesNotTrip() {
		XCTAssertFalse(
			MapParserArming.shouldDisarm(armedForDocument: true, mainFrameErrors: 12, renderedNothing: false),
			"the error listener is capturing and counts failed sub-resources; a 404 image is not a broken page"
		)
	}

	func testShouldDisarm_BlankWithoutErrors_DoesNotTrip() {
		XCTAssertFalse(
			MapParserArming.shouldDisarm(armedForDocument: true, mainFrameErrors: 0, renderedNothing: true),
			"a blank page that threw nothing is a slow application shell, not evidence against us"
		)
	}

	func testShouldDisarm_DocumentThatWasNotArmed_DoesNotTrip() {
		XCTAssertFalse(
			MapParserArming.shouldDisarm(armedForDocument: false, mainFrameErrors: 3, renderedNothing: true),
			"a page that broke without our script is not our page to disarm"
		)
	}
}

// MARK: - The seam that switches injection on and off

/// Proof that the arming decision reaches a real web view through the app's own delegate.
///
/// A test of `applyMapRegistry` alone would pass with the navigation delegate misdeclared, and a
/// *nearly* matching delegate signature is silently not a protocol witness — this file's subject
/// exists because AIA-0817 shipped a registry that was installed only by its own tests, and the
/// JavaScript dialog handlers in the same coordinator were once silently suppressed the same way.
/// So this drives an actual load through an actual `WKNavigationDelegate`.
@MainActor
final class MapParserArmingSeamTests: XCTestCase {

	private var settings: Settings!
	private var browserState: BrowserState!
	private var coordinator: MLWebView.Coordinator!
	private var webView: WKWebView!
	/// Held for the lifetime of the test: the coordinator's reference to the controller is weak, to
	/// avoid the cycle `WKUserContentController` creates by retaining its message handlers.
	private var configuration: WKWebViewConfiguration!
	private var originalSetting: Bool?

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		originalSetting = UserDefaults.standard.object(forKey: "readMapPositionFromPages") as? Bool
		settings.readMapPositionFromPages = true
		browserState = BrowserState(settings: settings)

		let view = MLWebView(.initial, renderer: WebSnapshotRenderer(adjustment: SnapAdjustment()))
		coordinator = view.makeCoordinator()
		coordinator.browserState = browserState

		// The SHIPPING controller, not one this test assembled: a test that builds its own cannot
		// notice the app's factory drifting away from it.
		configuration = WKWebViewConfiguration()
		configuration.userContentController = MLWebView.makeUserContentController(armed: true)
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320), configuration: configuration)
		webView.navigationDelegate = coordinator
		// What `makeUIView` does: hand the coordinator the controller instance itself, because
		// `WKWebView.configuration` returns a copy.
		coordinator.userContentController = configuration.userContentController
	}

	override func tearDown() async throws {
		MapParserArmingTests.restore(originalSetting, on: settings)
		webView.navigationDelegate = nil
		webView = nil
		configuration = nil
		coordinator = nil
		browserState = nil
		settings = nil
		try await super.tearDown()
	}

	private func harnessURL(_ name: String) throws -> URL {
		let bundle = Bundle(for: MapParserArmingTests.self)
		guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "MapHarness")
			?? bundle.url(forResource: name, withExtension: "html")
		else {
			throw XCTSkip("harness page \(name).html is not in the test bundle")
		}
		return url
	}

	@discardableResult
	private func load(_ name: String) async throws -> Bool {
		let url = try harnessURL(name)
		webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

		let deadline = Date().addingTimeInterval(20)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(60))
			let ready = try? await webView.evaluateJavaScript("window.__harnessReady === true")
			if (ready as? Bool) == true { return true }
		}
		XCTFail("\(name).html never signalled readiness")
		return false
	}

	private func registryIsPresent() async -> Bool {
		let value = try? await webView.evaluateJavaScript("typeof window.__aiaMapRegistry === 'object'")
		return (value as? Bool) == true
	}

	/// The platform behaviour the whole seam rests on.
	///
	/// `WKWebView.configuration` is `@NSCopying`, so the configuration handed back is a copy. What
	/// matters is whether the copy still points at the SAME `WKUserContentController` — because a
	/// great deal of code reaches for the controller that way, and if the copy ever stopped sharing
	/// it, every such change would silently stop reaching the page. The app itself does not depend
	/// on this (the coordinator holds the instance), so this test is a tripwire on the assumption
	/// rather than a check on the feature.
	func testWebViewConfiguration_SharesTheContentControllerInstance() {
		XCTAssertTrue(
			webView.configuration.userContentController === configuration.userContentController,
			"the web view's configuration copy no longer shares the content controller; the arming seam needs another mechanism"
		)
	}

	/// Armed, the registry reaches the page — otherwise every other assertion here is vacuous.
	func testArmed_TheRegistryReachesThePage() async throws {
		try await load("map_bundle_namespace")
		let present = await registryIsPresent()
		XCTAssertTrue(present, "the registry did not run; the injection is broken, not merely switchable")
	}

	/// The switch, end to end: flipping the setting and loading again must produce a document with
	/// no registry in it. This is the assertion that fails if `decidePolicyFor` is not a witness.
	func testSwitchedOffBetweenLoads_TheNextDocumentHasNoRegistry() async throws {
		try await load("map_bundle_namespace")
		let armedRun = await registryIsPresent()
		XCTAssertTrue(armedRun, "precondition: the first load must be armed")

		settings.readMapPositionFromPages = false
		try await load("map_none")

		let disarmedRun = await registryIsPresent()
		XCTAssertFalse(
			disarmedRun,
			"""
			the registry survived the switch being turned off. Either the navigation delegate method \
			is not a protocol witness (a nearly-matching signature is silently ignored), or the \
			script list was rebuilt too late for this document.
			"""
		)
	}

	/// A rebuild must not take the other scripts with it. `WKUserContentController` has no
	/// per-script removal, so every arming change rebuilds the whole list — and the frame-announce
	/// and diagnostics scripts are the two the breaker and the probe depend on.
	func testDisarmed_TheOtherScriptsSurviveTheRebuild() {
		let controller = MLWebView.makeUserContentController(armed: false)
		XCTAssertTrue(
			controller.userScripts.contains { $0.source.contains("interactionHandler") },
			"touch detection was collateral damage of disarming the map parser"
		)
		XCTAssertTrue(
			controller.userScripts.contains { $0.source.contains("aiaPageDiagnostics") },
			"the diagnostics script is what the breaker keys on; disarming must not remove it"
		)
		XCTAssertFalse(
			controller.userScripts.contains { $0.source == MapProbeScript.registry },
			"a disarmed controller still carried the registry"
		)
	}
}

// MARK: - The regression the ticket asks for

/// A page that performs the `window` operations bundles perform must still render with our script
/// injected.
///
/// The accessor-based registry that AIA-0817 shipped during development broke americanamap.org,
/// openlayers.org and basemap.at outright: they rendered nothing. This pins the *class* of
/// operation rather than one symptom, because a transparent accessor with a backing store would
/// survive a narrower check while still being the thing that broke real sites.
@MainActor
final class MapRegistryPageDamageTests: XCTestCase {

	private var webView: WKWebView!

	/// Every global the registry watches, plus the module-loader names whose wrapping was what broke
	/// americanamap.org outright.
	private let watchedGlobals = [
		"L", "ol", "OpenLayers", "maplibregl", "mapboxgl", "google",
		"Potree", "deck", "esri", "Cesium", "define", "require"
	]

	override func setUp() async throws {
		try await super.setUp()
		let configuration = WKWebViewConfiguration()
		// The shipping controller, armed.
		configuration.userContentController = MLWebView.makeUserContentController(armed: true)
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320), configuration: configuration)
	}

	override func tearDown() async throws {
		webView = nil
		try await super.tearDown()
	}

	private func loadFixture() async throws {
		let bundle = Bundle(for: Self.self)
		guard let url = bundle.url(forResource: "map_bundle_namespace", withExtension: "html", subdirectory: "MapHarness")
			?? bundle.url(forResource: "map_bundle_namespace", withExtension: "html")
		else {
			throw XCTSkip("map_bundle_namespace.html is not in the test bundle")
		}
		webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

		let deadline = Date().addingTimeInterval(20)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(60))
			let ready = try? await webView.evaluateJavaScript("window.__harnessReady === true")
			if (ready as? Bool) == true { return }
		}
		XCTFail("map_bundle_namespace.html never signalled readiness")
	}

	/// The page must complete its bootstrap and render.
	func testBundleBootstrapPage_StillRenders() async throws {
		try await loadFixture()

		let failures = try await webView.evaluateJavaScript("window.__fixtureFailures.join(' | ')") as? String
		XCTAssertEqual(failures, "", "the injected registry broke the page's own bootstrap")

		let sentinel = try await webView.evaluateJavaScript(
			"!!document.getElementById('bundle-sentinel')"
		) as? Bool
		XCTAssertEqual(sentinel, true, "the page rendered nothing — exactly the failure this ticket exists to prevent")
	}

	/// The registry's constructor trap was really installed and really met.
	///
	/// The page renders identically whether `traceConstructor` wrapped anything or silently never
	/// ran, so without this the rendering assertions above would pass against a registry that had
	/// quietly stopped working — and the claim that the fixture exercises the Proxy would be a
	/// comment rather than a fact.
	///
	/// The evidence is that the registry's instance list GREW when the fixture constructed. An
	/// earlier version asked whether `Potree.Viewer.__aiaTraced` was set, which proves nothing:
	/// `defineProperty` on a `Proxy` forwards to its target, so the original constructor carries
	/// that marker whether or not the wrapper was ever installed (raised in review).
	func testBundleBootstrapPage_MetTheTracedConstructor() async throws {
		try await loadFixture()
		let traced = try await webView.evaluateJavaScript("window.__viewerWasTraced === true") as? Bool
		XCTAssertEqual(
			traced,
			true,
			"Potree.Viewer was not wrapped when the page constructed through it — either the poller never ran or traceConstructor bailed"
		)
	}

	/// Not vacuous: the registry really did run against this page.
	///
	/// Without this, a registry that silently failed to install would make every other assertion
	/// here pass for the wrong reason.
	func testBundleBootstrapPage_TheRegistryActuallyRan() async throws {
		try await loadFixture()
		let present = try await webView.evaluateJavaScript("typeof window.__aiaMapRegistry === 'object'") as? Bool
		XCTAssertEqual(present, true, "the registry never ran, so this suite proves nothing about it")
	}

	/// The invariant behind the original breakage: the registry must leave every watched global as a
	/// plain DATA property. An accessor is what broke real pages, and it is the first thing a future
	/// change would reintroduce.
	func testWatchedGlobals_RemainDataPropertiesNotAccessors() async throws {
		try await loadFixture()

		for name in watchedGlobals {
			// The descriptor as the page found it at document start, BEFORE the fixture redefined
			// anything. Reading it now would prove nothing: the fixture's own `defineProperty` would
			// have overwritten a configurable accessor, and the test would agree with itself.
			let kind = try await webView.evaluateJavaScript(
				"window.__descriptorsAtStart['\(name)']"
			) as? String
			XCTAssertNotEqual(
				kind,
				"accessor",
				"window.\(name) was an accessor when the page started. Installing an accessor for this name is what rendered americanamap.org blank."
			)
		}
		let readError = try await webView.evaluateJavaScript("window.__descriptorsAtStart.error || ''") as? String
		XCTAssertEqual(readError, "", "the descriptors could not be read, so this test proved nothing")
	}
}

// MARK: - The breaker, end to end

/// Serves a page that throws during start-up and renders nothing, at a URL that HAS a host.
///
/// The host is the whole reason this exists. Every other fixture in this suite is loaded from
/// `file://`, which has no host at all — so `documentHost` is nil, the breaker can never trip, and
/// no harness test could ever exercise it. A custom scheme fixes that: WebKit gives custom-scheme
/// URLs a real host and still injects user scripts into them.
private final class BlankPageSchemeHandler: NSObject, WKURLSchemeHandler {

	/// How many times a document has been requested. The breaker's reload is observable as a second
	/// request, which is the only way to see it from outside.
	private(set) var requestCount = 0

	private let html = """
	<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
	<script>throw new Error('bootstrap failed');</script>
	</body></html>
	"""

	func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
		requestCount += 1
		guard let url = urlSchemeTask.request.url else {
			urlSchemeTask.didFailWithError(URLError(.badURL))
			return
		}
		let data = Data(html.utf8)
		let response = URLResponse(
			url: url,
			mimeType: "text/html",
			expectedContentLength: data.count,
			textEncodingName: "utf-8"
		)
		urlSchemeTask.didReceive(response)
		urlSchemeTask.didReceive(data)
		urlSchemeTask.didFinish()
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// The path the ticket is actually about: a page that throws and renders nothing must cost the
/// site its parser, not cost the user the page.
///
/// Everything else in this file tests a piece — the arbiter, the pure predicate, the injection
/// seam. None of them would have caught evidence from one document being counted against the next,
/// because none of them can make the breaker fire at all.
@MainActor
final class MapParserBreakerEndToEndTests: XCTestCase {

	private var settings: Settings!
	private var browserState: BrowserState!
	private var coordinator: MLWebView.Coordinator!
	private var webView: WKWebView!
	private var configuration: WKWebViewConfiguration!
	private var handler: BlankPageSchemeHandler!
	private var originalSetting: Bool?

	private let pageURL = URL(string: "aiatest://blank.example/index.html")

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		originalSetting = UserDefaults.standard.object(forKey: "readMapPositionFromPages") as? Bool
		settings.readMapPositionFromPages = true
		browserState = BrowserState(settings: settings)

		let view = MLWebView(.initial, renderer: WebSnapshotRenderer(adjustment: SnapAdjustment()))
		coordinator = view.makeCoordinator()
		coordinator.browserState = browserState

		handler = BlankPageSchemeHandler()
		configuration = WKWebViewConfiguration()
		configuration.userContentController = MLWebView.makeUserContentController(armed: true)
		configuration.setURLSchemeHandler(handler, forURLScheme: "aiatest")

		// What `makeUIView` registers alongside the scripts. The message HANDLERS are not part of
		// `makeUserContentController`, and without this one the diagnostics script posts into
		// nothing: the error count stays zero and the breaker can never reach its trip condition.
		// (Getting this wrong is what made the first version of this test fail.)
		configuration.userContentController.add(coordinator, name: "aiaPageDiagnostics")

		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320), configuration: configuration)
		webView.navigationDelegate = coordinator
		coordinator.userContentController = configuration.userContentController
		coordinator.installedArmed = true
		// So the breaker's reload, which is routed through BrowserState, has a web view to reach.
		browserState.attach(webView)
	}

	override func tearDown() async throws {
		MapParserArmingTests.restore(originalSetting, on: settings)
		configuration.userContentController.removeScriptMessageHandler(forName: "aiaPageDiagnostics")
		webView.navigationDelegate = nil
		webView = nil
		configuration = nil
		handler = nil
		coordinator = nil
		browserState = nil
		settings = nil
		try await super.tearDown()
	}

	/// Waits for a condition rather than a fixed delay, but with a real ceiling: the blank verdict
	/// is deliberately taken two seconds after the load finishes, and the diagnostics script reports
	/// at two and eight seconds, so this is inherently a slow test.
	private func wait(upTo seconds: TimeInterval, for condition: () -> Bool) async {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(100))
		}
	}

	func testAPageThatThrowsAndRendersNothing_DisarmsItsHostAndReloadsOnce() async throws {
		let url = try XCTUnwrap(pageURL)
		webView.load(URLRequest(url: url))

		await wait(upTo: 20) { self.browserState.mapParserArming.hasTripped(host: "blank.example") }

		XCTAssertTrue(
			browserState.mapParserArming.hasTripped(host: "blank.example"),
			"a page that threw and rendered nothing did not disarm its host — the breaker never fired"
		)
		XCTAssertFalse(
			browserState.mapParserArming.isArmed(for: url),
			"the host was recorded as failed but is still armed"
		)

		// The reload is only observable from outside as a second request for the document.
		await wait(upTo: 5) { self.handler.requestCount >= 2 }
		XCTAssertGreaterThanOrEqual(
			handler.requestCount,
			2,
			"the breaker disarmed the host but never reloaded, so the user is still looking at the blank page"
		)

		// The reloaded document must be the one that runs without the registry.
		//
		// Asserted as an explicit `false`, never as "not true": a failed evaluation yields nil, and
		// `XCTAssertNotEqual(nil, true)` would pass while proving nothing at all (raised in review).
		// Waiting for the evaluation to succeed also waits for the reloaded document to commit,
		// which `requestCount` alone does not — it observes a request starting, not a page arriving.
		var registryPresent: Bool?
		let evaluationDeadline = Date().addingTimeInterval(10)
		while Date() < evaluationDeadline {
			if let answer = try? await webView.evaluateJavaScript(
				"typeof window.__aiaMapRegistry === 'object'"
			) as? Bool, answer == false {
				registryPresent = answer
				break
			}
			try? await Task.sleep(for: .milliseconds(200))
		}
		XCTAssertEqual(
			registryPresent,
			false,
			"the reloaded document either never committed or still carries the registry, so the reload fixes nothing"
		)
	}

	/// One reload per host per session — the guard that stops an auto-reload becoming a loop.
	func testASecondFailureOnTheSameHost_DoesNotReloadAgain() async throws {
		let url = try XCTUnwrap(pageURL)
		webView.load(URLRequest(url: url))
		await wait(upTo: 20) { self.browserState.mapParserArming.hasTripped(host: "blank.example") }
		try XCTSkipIf(
			browserState.mapParserArming.hasTripped(host: "blank.example") == false,
			"the breaker did not trip; the first test reports that failure"
		)

		XCTAssertFalse(
			browserState.mapParserArming.recordFailure(host: "blank.example"),
			"the host's one automatic reload was already spent and must not be granted twice"
		)
	}
}
