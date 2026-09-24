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
