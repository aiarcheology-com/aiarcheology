//
//  BrowserStateCaptureURLTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: which URL a finding records.
//
//  Both existing URLs are wrong for this. `displayedURL` is throttled and shows the *requested*
//  address during a user load, while the old page is still on screen. `currentURL` is raw KVO,
//  which can already hold a provisional URL for a document that does not exist yet. A finding must
//  record the page whose pixels were captured.
//

import WebKit
import XCTest
@testable import ML_Browser

@MainActor
final class BrowserStateCaptureURLTests: XCTestCase {

	private var settings: Settings!
	private var state: BrowserState!
	private var webView: WKWebView!
	private var originalLastPage: URL?

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		// Settings persists to UserDefaults.standard; keep the suite clean for everyone else.
		originalLastPage = settings.lastPage
		settings.lastPage = nil
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
		state = BrowserState(settings: settings)
		state.attach(webView)
	}

	override func tearDown() async throws {
		settings.lastPage = originalLastPage
		state = nil
		webView = nil
		settings = nil
		try await super.tearDown()
	}

	/// Loads a document, waits for the KVO sink, and simulates the commit the app would deliver.
	///
	/// The commit is not optional decoration. In the app `MLWebView`'s coordinator forwards
	/// `didCommit` to `BrowserState`, which is what stamps `committedURL`; this test owns a bare
	/// `WKWebView` with no delegate, so without this the state under test never reaches the shape it
	/// always has in production, and the tests would be describing a situation that cannot occur.
	private func load(_ html: String, at url: URL) async {
		webView.loadHTMLString(html, baseURL: url)
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(50))
			if webView.isLoading == false, webView.url != nil { break }
		}
		await settle()
		state.navigationCommitted(nil, from: webView)
		await settle()
	}

	private func settle() async {
		try? await Task.sleep(for: .milliseconds(150))
	}

	// MARK: - The committed page, not the requested one

	/// The failure this prevents: the user types an address, then taps a detection on the page
	/// still rendered underneath. The finding must record what was on screen, not the destination.
	func testDuringAUserLoad_CaptureURLIsTheRenderedPage_NotTheRequestedOne() async {
		await load("<p>rendered</p>", at: URL(string: "https://example.org/rendered")!)
		let rendered = state.captureURL
		XCTAssertNotNil(rendered)

		state.userLoadRequested("https://example.org/requested")
		await settle()

		XCTAssertEqual(state.displayedURL?.absoluteString, "https://example.org/requested",
		               "the address bar shows where we are going")
		XCTAssertEqual(state.captureURL, rendered,
		               "a finding must not claim the page that is only being fetched")
	}

	// MARK: - Same-document navigation: the map pan

	/// The case this ticket exists for. `pushState`/`replaceState` never commit, and
	/// `WKNavigationDelegate` has no public same-document callback, so the KVO stream is the only
	/// signal available — `captureURL` has to follow it or a pan is never recorded.
	func testReplaceState_AdvancesCaptureURL() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		_ = try? await webView.evaluateJavaScript(
			"history.replaceState(null, '', '/map#map=15/47.941230/18.709545'); true"
		)
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "map=15/47.941230/18.709545")
	}

	func testPushState_FeedsTheResolver() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		_ = try? await webView.evaluateJavaScript(
			"history.pushState(null, '', '/map#map=15/47.941230/18.709545'); true"
		)
		await settle()

		let location = MapLocationResolver.resolve(url: state.captureURL)
		XCTAssertEqual(location.reading?.coordinate.latitude ?? 0, 47.941230, accuracy: 0.0000001)
		XCTAssertEqual(location.reading?.coordinate.longitude ?? 0, 18.709545, accuracy: 0.0000001)
	}

	/// Rapid same-document updates: the newest one wins, and the capture path notices they were
	/// same-document at all.
	///
	/// **Named for what it proves.** It was called `…IsNotSubjectToTheAddressBarThrottle`, and it did
	/// not show that: it waits past the 100 ms window, by which point the throttled address bar has
	/// caught up too, so both values agree and neither path is distinguished (raised in review). The
	/// contrast is genuinely time-dependent — the throttle is a wall-clock timer with no injected
	/// clock — so asserting it would mean asserting that a 100 ms deadline was not met on a loaded CI
	/// machine, which is a flake rather than a proof. What *is* deterministic is latest-wins over five
	/// updates, and that the same-document marker was raised: no navigation committed here, so a
	/// `captureURL` that moved at all moved through the KVO path this feature added.
	func testCaptureURL_TracksRapidSameDocumentUpdates_LatestWins() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		for index in 1...5 {
			_ = try? await webView.evaluateJavaScript(
				"history.replaceState(null, '', '/map#step\(index)'); true"
			)
		}
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "step5", "the newest pan must be the one recorded")
		XCTAssertTrue(
			state.hasObservedSameDocumentURLChange,
			"the URL moved without a commit, so the same-document path is what moved it"
		)
	}

	// MARK: - The in-flight marker must always clear

	/// The regression this pins: `navigationFailed` returns early for an unclassified error and for
	/// a provisional failure over committed content. Clearing the marker after those guards would
	/// freeze `captureURL` for the rest of the session, and no later pan would ever be recorded.
	func testUnclassifiedFailure_DoesNotFreezeCaptureURL() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		state.navigationStarted(nil, from: webView)
		state.navigationFailed(
			nil,
			error: NSError(domain: "TestDomain", code: -1, userInfo: nil),
			provisional: true,
			from: webView
		)

		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#after'); true")
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "after", "the in-flight marker stuck")
	}

	/// While a different document is genuinely being fetched, a KVO update must not be mistaken for
	/// the page on screen.
	func testWhileANavigationIsInFlight_CaptureURLHolds() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)
		let beforeNavigation = state.captureURL

		state.navigationStarted(nil, from: webView)
		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#during'); true")
		await settle()

		XCTAssertEqual(state.captureURL, beforeNavigation, "a page being fetched is not the page on screen")

		state.navigationCommitted(nil, from: webView)
		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#settled'); true")
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "settled", "tracking must resume after the commit")
	}

	// MARK: - Fallback

	/// Attaching to an already-loaded web view produces no commit callback, yet a page is on
	/// screen. The fallback is what keeps the ticket's floor — always some URL — intact.
	///
	/// Arranged **without** `load`, which synthesizes the commit the app's coordinator would deliver
	/// — so the previous version of this test exercised the committed path and could not have failed
	/// if the fallback were deleted (raised in review). Here the document is loaded first and a fresh
	/// `BrowserState` attaches to it afterwards, which is the real situation: a mode switch rebuilds
	/// the state around a web view that is already showing a page.
	func testWithNoObservedCommit_StillReportsAURL() async {
		let url = URL(string: "https://example.org/already-here")!
		webView.loadHTMLString("<p>here</p>", baseURL: url)
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(50))
			if webView.isLoading == false, webView.url != nil { break }
		}

		let attaching = BrowserState(settings: settings)
		attaching.attach(webView)
		await settle()

		XCTAssertNotNil(
			attaching.captureURL,
			"a state that never saw a commit must still report the page that is on screen"
		)
	}
}

// MARK: - AIA-0846: the image and its location come from one capture context

/// Holds an async dependency (a snapshot, a map probe) until the test releases it, so the page can
/// be changed at an exact point between the dependency starting and returning. No sleeps order
/// anything here: the test waits for the dependency to have *started*, then acts.
@MainActor
private final class Held<Value: Sendable> {
	private var continuation: CheckedContinuation<Value, Never>?
	private(set) var startCount = 0

	func wait() async -> Value {
		startCount += 1
		return await withCheckedContinuation { continuation = $0 }
	}

	/// Bounded, so a broken seam fails readably instead of hanging the suite.
	func untilStarted(file: StaticString = #filePath, line: UInt = #line) async {
		let deadline = Date().addingTimeInterval(5)
		while continuation == nil {
			if Date() > deadline {
				XCTFail("the held dependency never started", file: file, line: line)
				return
			}
			await Task.yield()
		}
	}

	func release(_ value: Value) {
		guard let continuation else { return XCTFail("nothing is held") }
		self.continuation = nil
		continuation.resume(returning: value)
	}
}

@MainActor
private final class AskedURLs {
	var urls: [URL?] = []
}

extension BrowserStateCaptureURLTests {

	private var pageA: URL { URL(string: "https://example.org/a")! }
	private var pageB: URL { URL(string: "https://example.org/b")! }

	/// What a live map on the CURRENT page would answer: a real coordinate, so a result that carries
	/// it is unmistakably the live page's rather than the URL-only floor.
	private func liveAnswer(for url: URL?) -> MapPageLocation {
		MapPageLocation(
			sourceURL: url,
			reading: MapLocationReading(
				coordinate: MapCoordinate(latitude: 10.5, longitude: 20.5)!,
				source: .leaflet
			)
		)
	}

	/// Replaces the real probe with one that records the URL it was asked about and answers from
	/// `held` when given, immediately otherwise.
	private func stubResolver(held: Held<MapPageLocation>? = nil) -> () -> [URL?] {
		let recorder = AskedURLs()
		let live = liveAnswer(for:)
		state.locationResolver = { url, _, _, _, _ in
			recorder.urls.append(url)
			if let held { return await held.wait() }
			return live(url)
		}
		return { recorder.urls }
	}

	private func replaceState(_ path: String) async {
		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '\(path)'); true")
		await settle()
	}

	/// The web view is torn down and a new one attached, as the AIA-0509 rebuild does.
	private func replaceWebView() {
		state.webViewInvalidated()
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
		state.attach(webView)
	}

	// MARK: Context lifecycle

	func testContext_ReloadOfTheSameURL_IsAnotherDocument() async throws {
		await load("<p>A</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)

		// A reload commits a new document at the same address. URL equality cannot see it.
		state.navigationCommitted(nil, from: webView)

		XCTAssertEqual(state.captureURL, pageA)
		XCTAssertEqual(state.relation(of: context), .otherDocument)
	}

	func testContext_WebViewReplacement_IsAnotherDocument() async throws {
		await load("<p>A</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)

		replaceWebView()

		XCTAssertEqual(state.relation(of: context), .otherDocument)
	}

	func testContext_ReplaceState_IsSameDocumentDrift() async throws {
		await load("<p>map</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)

		await replaceState("/a#map=15/47.941230/18.709545")

		XCTAssertEqual(state.relation(of: context), .sameDocumentDrift)
	}

	/// While another document is being fetched `captureURL` deliberately holds still, so a map
	/// panning underneath would be invisible to it. The live URL is part of the context for exactly
	/// this: the rewrite still counts as the page having moved.
	func testContext_RewriteWhileAnotherDocumentLoads_IsStillDrift() async throws {
		await load("<p>map</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)

		state.navigationStarted(nil, from: webView)
		await replaceState("/a#moved")

		XCTAssertEqual(state.captureURL, context.sourceURL, "precondition: the recorded URL held still")
		XCTAssertEqual(state.relation(of: context), .sameDocumentDrift)
	}

	func testContext_NothingHappened_IsCurrent() async throws {
		await load("<p>A</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)

		XCTAssertEqual(state.relation(of: context), .current)
		XCTAssertEqual(context.sourceURL, pageA)
	}

	// MARK: Scenarios 1 and 2 — a retained frame is never enriched from another page

	func testRetainedFrame_AfterAnotherPageCommits_KeepsItsOwnURL_AndNeverAsksTheNewPage() async throws {
		await load("<p>A</p>", at: pageA)
		let frameContext = try XCTUnwrap(state.captureContext)
		await load("<p>B</p>", at: pageB)
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: frameContext)

		XCTAssertEqual(result, .resolved(MapPageLocation(sourceURL: pageA)))
		XCTAssertTrue(asked().isEmpty, "page B must not be probed to describe an image of page A")
	}

	func testRetainedFrame_AfterASameURLReload_IsNotEnrichedFromTheNewDocument() async throws {
		await load("<p>A</p>", at: pageA)
		let frameContext = try XCTUnwrap(state.captureContext)
		state.navigationCommitted(nil, from: webView)
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: frameContext)

		XCTAssertEqual(result, .resolved(MapPageLocation(sourceURL: pageA)))
		XCTAssertTrue(asked().isEmpty)
	}

	func testRetainedFrame_AfterWebViewReplacement_KeepsItsOwnURL() async throws {
		await load("<p>A</p>", at: pageA)
		let frameContext = try XCTUnwrap(state.captureContext)
		replaceWebView()
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: frameContext)

		XCTAssertEqual(result, .resolved(MapPageLocation(sourceURL: pageA)))
		XCTAssertTrue(asked().isEmpty)
	}

	/// Same document, moved on: the live map need not be showing what the frame shows, so it is not
	/// asked and the caller is told to get a fresh image.
	func testRetainedFrame_AfterReplaceState_IsDrifted_AndNotProbed() async throws {
		await load("<p>map</p>", at: pageA)
		let frameContext = try XCTUnwrap(state.captureContext)
		await replaceState("/a#map=15/47.941230/18.709545")
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: frameContext)

		XCTAssertEqual(result, .drifted)
		XCTAssertTrue(asked().isEmpty)
	}

	// MARK: Scenario 4 — the page changes while the probe is out

	private func assertProbeAnswerDropped(
		when change: () async -> Void,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		await load("<p>map</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)
		let held = Held<MapPageLocation>()
		let asked = stubResolver(held: held)

		let resolving = Task { await state.resolveCaptureLocation(for: context) }
		await held.untilStarted(file: file, line: line)
		await change()
		held.release(liveAnswer(for: state.captureURL))
		let result = await resolving.value

		XCTAssertEqual(asked(), [pageA], "the probe was asked about the frame's page", file: file, line: line)
		XCTAssertEqual(
			result,
			.resolved(MapPageLocation(sourceURL: pageA)),
			"an answer that arrived after the page changed must not be kept",
			file: file,
			line: line
		)
	}

	func testProbe_AnotherPageCommitsMidProbe_AnswerDropped_URLKept() async throws {
		try await assertProbeAnswerDropped { await load("<p>B</p>", at: pageB) }
	}

	/// A redirect is a commit of a different URL; a reload is a commit of the same one.
	func testProbe_SameURLReloadMidProbe_AnswerDropped_URLKept() async throws {
		try await assertProbeAnswerDropped { state.navigationCommitted(nil, from: webView) }
	}

	func testProbe_ReplaceStateMidProbe_AnswerDropped_URLKept() async throws {
		try await assertProbeAnswerDropped { await replaceState("/a#elsewhere") }
	}

	func testProbe_WebViewReplacedMidProbe_AnswerDropped_URLKept() async throws {
		try await assertProbeAnswerDropped { replaceWebView() }
	}

	/// The page ends where it started, but it was somewhere else while the probe was out; the answer
	/// may describe the detour.
	func testProbe_URLRoundTripMidProbe_AnswerDropped_URLKept() async throws {
		try await assertProbeAnswerDropped {
			await replaceState("/a#detour")
			await replaceState("/a")
		}
	}

	// MARK: Positive controls

	/// A heavy map app can keep loading long after its document committed, and while it does the
	/// recorded URL holds still. A pan made then, BEFORE the snapshot, is part of what the image shows,
	/// so the live map is still asked and its answer kept.
	func testProbe_RewriteWhileLoadingBeforeTheSnapshot_StillKeepsTheLiveAnswer() async throws {
		await load("<p>map</p>", at: pageA)
		state.navigationStarted(nil, from: webView)
		await replaceState("/a#panned")
		let context = try XCTUnwrap(state.captureContext)
		XCTAssertNotEqual(context.sourceURL, context.liveURL, "precondition: the recorded URL is held")
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: context)

		XCTAssertEqual(asked(), [pageA])
		XCTAssertEqual(result, .resolved(liveAnswer(for: pageA)))
	}

	func testProbe_UnchangedPage_KeepsTheLiveAnswer() async throws {
		await load("<p>map</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)
		let asked = stubResolver()

		let result = await state.resolveCaptureLocation(for: context)

		XCTAssertEqual(asked(), [pageA])
		XCTAssertEqual(result, .resolved(liveAnswer(for: pageA)))
	}

	func testProbe_NoCoordinateAvailable_StillRecordsThePage() async throws {
		await load("<p>article</p>", at: pageA)
		let context = try XCTUnwrap(state.captureContext)
		state.locationResolver = { url, _, _, _, _ in MapPageLocation(sourceURL: url) }

		let result = await state.resolveCaptureLocation(for: context)

		XCTAssertEqual(result, .resolved(MapPageLocation(sourceURL: pageA)))
	}

	// MARK: Scenario 3 — a fresh snapshot is bound to the page it came from

	private func assertSnapshotRefused(
		when change: () async -> Void,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		await load("<p>A</p>", at: pageA)
		let held = Held<String?>()

		let capturing = Task { await state.captureSnapshot { await held.wait() } }
		await held.untilStarted(file: file, line: line)
		await change()
		held.release("pixels of whatever is on screen now")

		guard case .documentChanged = await capturing.value else {
			return XCTFail("pixels taken across a page change must not be attributed to either page", file: file, line: line)
		}
	}

	func testSnapshot_AnotherPageCommitsMidSnapshot_IsRefused() async {
		await assertSnapshotRefused { await load("<p>B</p>", at: pageB) }
	}

	func testSnapshot_SameURLReloadMidSnapshot_IsRefused() async {
		await assertSnapshotRefused { state.navigationCommitted(nil, from: webView) }
	}

	func testSnapshot_ReplaceStateMidSnapshot_IsRefused() async {
		await assertSnapshotRefused { await replaceState("/a#elsewhere") }
	}

	func testSnapshot_WebViewReplacedMidSnapshot_IsRefused() async {
		await assertSnapshotRefused { replaceWebView() }
	}

	func testSnapshot_UnchangedPage_IsBoundToIt() async throws {
		await load("<p>A</p>", at: pageA)
		let expected = try XCTUnwrap(state.captureContext)

		let result = await state.captureSnapshot { "pixels of A" }

		guard case let .captured(image, context) = result else { return XCTFail("expected a capture") }
		XCTAssertEqual(image, "pixels of A")
		XCTAssertEqual(context, expected)
		XCTAssertEqual(context.sourceURL, pageA)
	}

	func testSnapshot_NoWebView_IsUnavailable_AndNeverTaken() async {
		let detached = BrowserState(settings: settings)
		var taken = false

		let result = await detached.captureSnapshot { () -> String? in
			taken = true
			return "pixels"
		}

		guard case .unavailable = result else { return XCTFail("expected unavailable") }
		XCTAssertFalse(taken)
	}

	func testSnapshot_NoImage_IsUnavailable() async {
		await load("<p>A</p>", at: pageA)

		let result = await state.captureSnapshot { () -> String? in nil }

		guard case .unavailable = result else { return XCTFail("expected unavailable") }
	}

	/// The whole manual path in order: snapshot first, then the location for THAT snapshot's context.
	/// Page B committing after the snapshot cannot lend the finding its URL or coordinate.
	func testFreshCapture_PageChangesAfterTheSnapshot_LocationStaysWithTheImage() async throws {
		await load("<p>A</p>", at: pageA)
		let asked = stubResolver()

		guard case let .captured(image, context) = await state.captureSnapshot({ "pixels of A" }) else {
			return XCTFail("expected a capture")
		}
		await load("<p>B</p>", at: pageB)
		let location = await state.resolveCaptureLocation(for: context)

		XCTAssertEqual(image, "pixels of A")
		XCTAssertEqual(location, .resolved(MapPageLocation(sourceURL: pageA)))
		XCTAssertTrue(asked().isEmpty)
	}
}

// MARK: - AIA-0875: a URL the app wrote is the app's own before the first pan too

/// Records what `resolveCaptureLocation` told the resolver about the page.
@MainActor
private final class MaintainedFlags {
	var values: [Bool] = []
}

/// Holds every subresource of a `held:` page until released, so a document can be kept loading —
/// committed, `isLoading` still true — for exactly as long as a test needs.
@MainActor
private final class HeldResourceHandler: NSObject, WKURLSchemeHandler {
	private(set) var held: [any WKURLSchemeTask] = []

	func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
		held.append(urlSchemeTask)
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
		held.removeAll { $0 === urlSchemeTask }
	}

	func releaseAll() {
		for task in held {
			guard let url = task.request.url else { continue }
			task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: 0, textEncodingName: nil))
			task.didFinish()
		}
		held = []
	}
}

/// Forwards the two navigation callbacks `MLWebView`'s coordinator forwards in the app, with the
/// real navigation tokens, so the commit lands at the moment WebKit actually commits.
@MainActor
private final class NavigationForwarder: NSObject, WKNavigationDelegate {
	weak var state: BrowserState?

	func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
		state?.navigationStarted(navigation, from: webView)
	}

	func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
		state?.navigationCommitted(navigation, from: webView)
	}
}

extension BrowserStateCaptureURLTests {

	/// An address a map app writes itself, in its own projected grid: the shape atlas.bayern.de keeps
	/// in `?c=`. Percent-encoding is included so the restore match is shown to survive it.
	private var appWritten: URL {
		URL(string: "https://example.org/atlas/?c=4471000.5,5334000.25&z=14&l=vt%20standard&mid=1")!
	}

	/// A live map holding its view in a DIFFERENT projected system. `unitsAgree` only separates
	/// degrees from not-degrees, so the refresh cannot see that these are not the URL's numbers.
	private var otherProjectionProbe: MapLocationProbe.Result {
		MapLocationProbe.Result(
			reading: nil,
			canonicalURL: nil,
			metadataReading: nil,
			libraries: [],
			nativeExtent: nil,
			nativeCenter: [1_280_000, 6_130_000],
			nativeWkid: 3857
		)
	}

	/// Replaces the probe with a fixed live map, but keeps the REAL resolver, so what is recorded is
	/// what the app would record given the flag `BrowserState` handed over.
	private func realResolver(probe: MapLocationProbe.Result) -> () -> [Bool] {
		let flags = MaintainedFlags()
		state.locationResolver = { url, _, _, maintained, _ in
			flags.values.append(maintained)
			return MapLocationResolver.resolve(url: url, probe: probe, pageMaintainsItsURL: maintained)
		}
		return { flags.values }
	}

	private func recordedURL(file: StaticString = #filePath, line: UInt = #line) async throws -> URL? {
		let context = try XCTUnwrap(state.captureContext, file: file, line: line)
		guard case let .resolved(location) = await state.resolveCaptureLocation(for: context) else {
			XCTFail("expected a resolved location", file: file, line: line)
			return nil
		}
		return location.sourceURL
	}

	private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
		let deadline = Date().addingTimeInterval(15)
		while condition() == false {
			if Date() > deadline { return XCTFail("condition never became true", file: file, line: line) }
			try? await Task.sleep(for: .milliseconds(50))
		}
	}

	/// The fixture only proves something if the refresh WOULD rewrite this URL for a page taken as
	/// frozen; otherwise every assertion below would pass whatever flag reached the resolver.
	func testFixture_IsRewrittenWhenThePageIsTakenAsFrozen() {
		let refreshed = MapLocationResolver.resolve(
			url: appWritten, probe: otherProjectionProbe, pageMaintainsItsURL: false
		).sourceURL
		XCTAssertNotEqual(refreshed, appWritten)
		XCTAssertTrue(refreshed?.absoluteString.contains("c=1280000,6130000") ?? false)
	}

	/// The ticket's acceptance case: Reopen Last Page onto a map that maintains `?c=` in its own
	/// projection, and a finding saved before any pan records the app's URL byte for byte.
	func testReopenedLastPage_BeforeAnyPan_RecordsTheAppsOwnURL() async throws {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		let flags = realResolver(probe: otherProjectionProbe)
		state.lastPageRestoreRequested(appWritten)

		await visit("<p>map</p>", at: appWritten)
		let recorded = try await recordedURL()

		XCTAssertEqual(flags(), [true], "the restore must reach the resolver as a page that keeps its URL")
		XCTAssertEqual(recorded?.absoluteString, appWritten.absoluteString)
	}

	/// The AIA-0817 control at `BrowserState` level: an ordinary visit with nothing seen still gets
	/// the frozen-URL refresh. This fails if the new signal is ever applied unconditionally.
	func testOrdinaryVisit_BeforeAnyPan_StillGetsTheFrozenURLRefresh() async throws {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		let flags = realResolver(probe: otherProjectionProbe)

		await visit("<p>map</p>", at: appWritten)
		let recorded = try await recordedURL()

		XCTAssertEqual(flags(), [false])
		XCTAssertTrue(recorded?.absoluteString.contains("c=1280000,6130000") ?? false, "\(String(describing: recorded))")
	}

	/// One-shot: whatever commits first consumes the request, and only a match counts. A later
	/// visit to the saved address is an ordinary visit.
	func testRestoreRequest_IsConsumedByTheFirstCommit_EvenWithoutAMatch() async throws {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		let flags = realResolver(probe: otherProjectionProbe)
		state.lastPageRestoreRequested(appWritten)

		await visit("<p>elsewhere</p>", at: pageB)
		XCTAssertFalse(state.pageMaintainsItsURL, "another page committing first is not the restore")
		await visit("<p>map</p>", at: appWritten)
		_ = try await recordedURL()

		XCTAssertEqual(flags(), [false])
	}

	/// A load the user asked for replaces the restore before anything commits.
	func testUserLoad_WithdrawsTheRestoreRequest() async {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		state.lastPageRestoreRequested(appWritten)
		state.userLoadRequested(appWritten.absoluteString)

		await visit("<p>map</p>", at: appWritten)

		XCTAssertFalse(state.pageMaintainsItsURL)
	}

	/// A reload of a page seen maintaining its URL reopens that page's own address; it must not have
	/// to be seen rewriting it again before a finding stops refreshing it.
	func testReloadOfAMaintainedPage_KeepsTreatingItsURLAsItsOwn() async throws {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		await visit("<p>map</p>", at: pageA)
		await replaceState("/a?c=4471000.5,5334000.25")
		XCTAssertTrue(state.hasObservedSameDocumentURLChange, "precondition: the page maintains its URL")
		let flags = realResolver(probe: otherProjectionProbe)
		let own = try XCTUnwrap(state.captureURL)

		state.navigationCommitted(nil, from: webView)
		XCTAssertFalse(state.hasObservedSameDocumentURLChange, "precondition: the observation was reset")
		let recorded = try await recordedURL()

		XCTAssertEqual(flags(), [true])
		XCTAssertEqual(recorded, own)
	}

	/// The same reload of a page never seen rewriting its URL is still an ordinary, refreshable page,
	/// and a different document after a maintained one starts from nothing.
	func testReload_OfAnUnmaintainedPage_OrNavigationAway_IsNotPresumed() async {
		let (handler, forwarder) = useRealNavigationCallbacks()
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }
		await visit("<p>map</p>", at: appWritten)
		state.navigationCommitted(nil, from: webView)
		XCTAssertFalse(state.pageMaintainsItsURL)

		await replaceState("/atlas/?c=1,2")
		XCTAssertTrue(state.pageMaintainsItsURL, "precondition")
		await visit("<p>B</p>", at: pageB)
		XCTAssertFalse(state.pageMaintainsItsURL)
	}

	// MARK: A rewrite while the document is still loading

	/// Replaces the test's web view with one that reports its navigations the way the app's
	/// coordinator does, and whose `held:` subresources never arrive until released.
	///
	/// The shared `load` helper will not do for this ticket: it synthesizes the commit only after
	/// loading has ended, by which time `resyncCommittedURL` has already adopted the new address, so a
	/// flag that depends on what the outgoing document was cannot be observed faithfully through it.
	private func useRealNavigationCallbacks() -> (HeldResourceHandler, NavigationForwarder) {
		let handler = HeldResourceHandler()
		let configuration = WKWebViewConfiguration()
		configuration.setURLSchemeHandler(handler, forURLScheme: "held")
		let forwarder = NavigationForwarder()
		forwarder.state = state
		state.webViewInvalidated()
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
		// `navigationDelegate` is weak; the caller keeps the forwarder alive with the handler.
		webView.navigationDelegate = forwarder
		state.attach(webView)
		return (handler, forwarder)
	}

	/// Loads a document through the real navigation callbacks and waits for it to finish.
	private func visit(_ html: String, at url: URL) async {
		let before = state.documentRevision
		webView.loadHTMLString(html, baseURL: url)
		await waitUntil { state.documentRevision != before && webView.isLoading == false && webView.url == url }
		await settle()
	}

	/// Loads `html` and returns once the document committed with a subresource still held.
	private func loadHeld(_ html: String, at url: URL) async -> (HeldResourceHandler, NavigationForwarder) {
		let (handler, forwarder) = useRealNavigationCallbacks()
		webView.loadHTMLString(html, baseURL: url)
		await waitUntil { state.hasCommittedContent && handler.held.isEmpty == false }
		await settle()
		return (handler, forwarder)
	}

	/// A map that writes its address while its resources are still arriving. `urlChanged` cannot tell
	/// that from a load being requested, so it does not follow it — and before AIA-0875 nothing
	/// recorded that the page had done it, so a capture then (or any time before the first pan)
	/// still took the refresh path.
	func testURLChangeWhileTheDocumentIsStillLoading_IsTakenAsTheAppsOwn() async throws {
		let base = URL(string: "held://example.org/map?c=4471000.5,5334000.25")!
		let (handler, forwarder) = await loadHeld("<img src='tile.png'><p>map</p>", at: base)
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }

		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map?c=4471200.5,5334100.25'); true")
		await settle()

		// Preconditions: the rewrite happened while loading, the old path did not see it, and the
		// recorded URL is held — so only the new signal can make the assertions below pass.
		XCTAssertTrue(webView.isLoading, "precondition: the document is still loading")
		XCTAssertEqual(webView.url?.absoluteString, "held://example.org/map?c=4471200.5,5334100.25")
		XCTAssertEqual(state.captureURL, base)
		XCTAssertFalse(state.hasObservedSameDocumentURLChange)
		let flags = realResolver(probe: otherProjectionProbe)

		let recorded = try await recordedURL()

		XCTAssertEqual(flags(), [true])
		XCTAssertEqual(recorded, base, "the held URL is recorded as it is, not rewritten from the live map")
	}

	/// Control: the same held load with no rewrite is an ordinary page.
	func testStillLoadingWithNoURLChange_IsNotPresumed() async {
		let base = URL(string: "held://example.org/map?c=4471000.5,5334000.25")!
		let (handler, forwarder) = await loadHeld("<img src='tile.png'><p>map</p>", at: base)
		defer { withExtendedLifetime(forwarder) { handler.releaseAll() } }

		XCTAssertTrue(webView.isLoading, "precondition: the document is still loading")
		XCTAssertFalse(state.pageMaintainsItsURL)
	}
}
