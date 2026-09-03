//
//  MapLocationProbeTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: the probe against real mapping libraries in a real WKWebView.
//
//  Leaflet and OpenLayers are vendored (test bundle only, never shipped) because the risky claims
//  are about *their* behaviour, not ours: that `L.Map.addInitHook` fires for a map built by the
//  `L.map(...)` factory, and that `ol.proj.toLonLat` converts a Web-Mercator view centre. A stub
//  would only prove the code agrees with the assumption it was written from.
//
//  ArcGIS is exercised through a faithful AMD-loader stand-in instead: the loader *protocol* is
//  what the trap codes against, and vendoring the multi-megabyte SDK belongs to the live harness.
//

import WebKit
import XCTest
@testable import ML_Browser

@MainActor
final class MapLocationProbeTests: XCTestCase {

	private var webView: WKWebView!

	override func setUp() async throws {
		try await super.setUp()
		let configuration = WKWebViewConfiguration()
		configuration.userContentController.addUserScript(
			WKUserScript(
				source: MapProbeScript.registry,
				injectionTime: .atDocumentStart,
				forMainFrameOnly: false
			)
		)
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320), configuration: configuration)
	}

	override func tearDown() async throws {
		webView = nil
		try await super.tearDown()
	}

	// MARK: - Harness plumbing

	private func harnessURL(_ name: String) throws -> URL {
		let bundle = Bundle(for: Self.self)
		guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "MapHarness")
			?? bundle.url(forResource: name, withExtension: "html")
		else {
			throw XCTSkip("harness page \(name).html is not in the test bundle")
		}
		return url
	}

	/// Loads a harness page and waits for its own readiness flag rather than a fixed delay, so the
	/// test is deterministic instead of timing-dependent.
	private func load(_ name: String) async throws {
		let url = try harnessURL(name)
		webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

		let deadline = Date().addingTimeInterval(20)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(60))
			let ready = try? await webView.evaluateJavaScript("window.__harnessReady === true")
			if (ready as? Bool) == true { return }
		}
		XCTFail("\(name).html never signalled readiness")
	}

	private func probe() async -> MapLocationProbe.Result {
		await MapLocationProbe(webView: webView).run()
	}

	private func assertCoordinate(
		_ result: MapLocationProbe.Result,
		latitude: Double,
		longitude: Double,
		source: MapLocationSource,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard let reading = result.reading else {
			XCTFail("expected a live-map reading", file: file, line: line)
			return
		}
		XCTAssertEqual(reading.coordinate.latitude, latitude, accuracy: 0.0001, "latitude", file: file, line: line)
		XCTAssertEqual(reading.coordinate.longitude, longitude, accuracy: 0.0001, "longitude", file: file, line: line)
		XCTAssertEqual(reading.source, source, file: file, line: line)
		XCTAssertEqual(reading.confidence, .exact, "a live map is exact", file: file, line: line)
	}

	// MARK: - Real libraries

	/// Proves the Leaflet claim end to end: the map is built with the `L.map(...)` factory, which
	/// closes over an internal class, so only `addInitHook` sees it.
	func testLeaflet_FactoryBuiltMap_IsFound() async throws {
		try await load("map_leaflet")
		assertCoordinate(await probe(), latitude: 47.941230, longitude: 18.709545, source: .leaflet)
	}

	func testLeaflet_ZoomIsReported() async throws {
		try await load("map_leaflet")
		let result = await probe()
		XCTAssertEqual(result.reading?.zoom, 15)
	}

	/// The view is EPSG:3857. A correct answer requires OpenLayers' own projection registry; reading
	/// the raw centre would yield Web-Mercator metres and fail the range check entirely.
	func testOpenLayers_WebMercatorView_IsConvertedByOpenLayersItself() async throws {
		try await load("map_openlayers")
		assertCoordinate(await probe(), latitude: 50.0755381, longitude: 14.4378005, source: .openLayers)
	}

	// MARK: - ArcGIS

	/// How a real ArcGIS app is reached: the app keeps its view on a global, and the duck-typed scan
	/// recognises it. Verified on tiris.maps.arcgis.com, which uses `window._viewerMap`.
	func testArcGIS_ViewOnAGlobal_IsFound() async throws {
		try await load("map_amd_arcgis")
		assertCoordinate(await probe(), latitude: 50.0755381, longitude: 14.4378005, source: .arcGIS)
	}

	/// A national-grid view where ArcGIS reports null for latitude/longitude, so the coordinate can
	/// only come from the SDK's own projection.
	///
	/// The fixture's view starts `ready: false` with no `center`, exactly as a real one measured on
	/// ags.cuzk.cz does. The earlier fixture handed over a ready view with coordinates already in
	/// place, so it passed while the shipped probe read too early and got nothing.
	func testArcGIS_ProjectedView_IsProjectedByTheSDK() async throws {
		try await load("map_amd_arcgis_projected")
		assertCoordinate(await probe(), latitude: 50.0755381, longitude: 14.4378005, source: .arcGIS)
	}

	/// Proves the probe waits rather than reading a half-built view.
	func testArcGIS_ViewNotReadyAtCaptureTime_IsWaitedFor() async throws {
		try await load("map_amd_arcgis_projected")
		let readyImmediately = try await webView.evaluateJavaScript("window.__view.ready === true") as? Bool
		XCTAssertEqual(readyImmediately, false, "the fixture must start unready or it proves nothing")
		let result = await probe()
		XCTAssertNotNil(result.reading, "the probe gave up before the view was usable")
	}

	/// The shape ags.cuzk.cz actually ships: an `<arcgis-map>` component with a live view, and no
	/// AMD loader at all — the SDK reachable only through `$arcgis.import`. An AMD-only projection
	/// path silently returns nothing here, which is what the ticket's own example was hitting.
	func testArcGIS_ESMWebComponent_ResolvesThroughDollarArcgis() async throws {
		try await load("map_esm_arcgis_component")
		let hasRequire = try await webView.evaluateJavaScript("typeof window.require") as? String
		XCTAssertEqual(hasRequire, "undefined", "the fixture must have no AMD loader")
		assertCoordinate(await probe(), latitude: 49.6835, longitude: 14.0421, source: .arcGIS)
	}

	/// The reported failure, reproduced: a national-grid view with no reachable projection module.
	///
	/// The projection attempt runs to its timeout and the script's deadline is spent — so anything
	/// gated behind it was skipped, including reading the viewport, which costs nothing and was
	/// available all along. The user saw a finding with no coordinate and an unchanged URL.
	func testArcGIS_NoProjectionModule_StillBanksTheViewport() async throws {
		try await load("map_arcgis_no_projection")
		let result = await probe()
		XCTAssertNil(result.reading, "a national grid yields no degrees, and none must be invented")
		XCTAssertEqual(result.nativeExtent?.first ?? 0, -832098.46, accuracy: 0.01,
		               "the viewport must be banked before the projection attempt, not after it")
		XCTAssertEqual(result.nativeWkid, 5514)
	}

	/// End to end for the reported case: no coordinate in degrees, but a named position and a URL
	/// whose viewport has been brought up to date from the live map.
	func testArcGIS_NoProjectionModule_RefreshesTheURLAndNamesTheSystem() async throws {
		try await load("map_arcgis_no_projection")
		let stale = URL(string: "https://example.org/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39&zvd=dmr5g")
		let location = MapLocationResolver.resolve(url: stale, probe: await probe())

		XCTAssertEqual(location.gpsPrefill, "S-JTSK (EPSG:5514): -828738.04, -1031271.56")
		let refreshed = location.sourceURL?.absoluteString ?? ""
		XCTAssertTrue(refreshed.contains("extent=-832098.46,-1032881.76,-825377.61,-1029661.35"), refreshed)
		XCTAssertTrue(refreshed.contains("zvd=dmr5g"), "the app's other parameters must survive")
	}

	// MARK: - The bundled majority

	/// Most Leaflet and OpenLayers sites in the target catalogue are framework bundles with no
	/// global at all. This is the strategy that reaches them, and the one most likely to rot.
	func testReactBackReference_FindsAModuleScopedMap() async throws {
		try await load("map_react_backref")
		// Labelled `.leaflet` rather than `.liveMap`: the container carries `leaflet-container` and
		// the object answers `getCenter()` with `{lat, lng}`, so naming the library is accurate.
		assertCoordinate(await probe(), latitude: 47.941230, longitude: 18.709545, source: .leaflet)
	}

	/// Proves the reading came from the back-reference walk and not from a constructor trap: the
	/// page loads no mapping library at all, so there is no global for any trap to have caught.
	func testReactBackReference_SucceedsWithNoLibraryGlobalPresent() async throws {
		try await load("map_react_backref")
		let hasGlobal = try await webView.evaluateJavaScript("typeof window.L !== 'undefined'") as? Bool
		XCTAssertEqual(hasGlobal, false, "the fixture must not expose a Leaflet global")
		let result = await probe()
		XCTAssertNotNil(result.reading)
	}

	// MARK: - Module-scoped maps (the ESM bundles)

	/// The case that defeated every other mechanism, verified in a real browser on openlayers.org:
	/// no global, and zero own properties on the container, the canvas and every ancestor. The map
	/// is reachable only because the library binds a method to it during construction.
	func testESMModuleScopedMap_IsCapturedByTheBindTrap() async throws {
		try await load("map_esm_module_scoped")
		let noGlobal = try await webView.evaluateJavaScript("typeof window.ol === 'undefined'") as? Bool
		XCTAssertEqual(noGlobal, true, "the fixture must expose no library global")
		let noExpandos = try await webView.evaluateJavaScript(
			"Object.keys(document.getElementById('map')).length === 0"
		) as? Bool
		XCTAssertEqual(noExpandos, true, "the fixture must expose no DOM back-reference")

		let result = await probe()
		XCTAssertEqual(result.nativeCenter?.first ?? 0, 1607296.6, accuracy: 0.1,
		               "the module-scoped map was not reached")
		XCTAssertEqual(result.nativeWkid, 3857)
	}

	/// A Web-Mercator view has no degrees to offer, so the position is recorded in its own system
	/// rather than discarded.
	func testESMModuleScopedMap_IsRecordedWithItsCoordinateSystem() async throws {
		try await load("map_esm_module_scoped")
		let location = MapLocationResolver.resolve(url: URL(string: "https://example.org/app"), probe: await probe())
		XCTAssertEqual(location.gpsPrefill, "Web Mercator (EPSG:3857): 1607296.6, 6461536.4")
	}

	// MARK: - A coordinate the page is showing

	/// Some portals display a readout and expose no reachable map at all. Copying the string the
	/// page already shows needs no library and no conversion.
	func testDisplayedCoordinate_IsReadFromThePage() async throws {
		try await load("map_displayed_coordinate")
		let result = await probe()
		XCTAssertNil(result.reading, "there is no live map on this page")
		XCTAssertEqual(result.metadataReading?.source, .displayedText)
		XCTAssertEqual(result.metadataReading?.coordinate.latitude ?? 0, 49.6835, accuracy: 0.0001)
		XCTAssertEqual(result.metadataReading?.rawText, "49.683500, 14.042100",
		               "the page's own spelling must survive")
	}

	// MARK: - Correct silence

	/// Roughly half the catalogue's "unknown" bucket is pages like this. No coordinate is the right
	/// answer, and the canonical link is still worth carrying.
	func testPageWithNoMap_YieldsNoReadingButKeepsCanonical() async throws {
		try await load("map_none")
		let result = await probe()
		XCTAssertNil(result.reading)
		XCTAssertNil(result.metadataReading)
		XCTAssertEqual(result.canonicalURL?.absoluteString, "https://example.org/canonical-page")
	}

	func testMetadataOnly_IsReportedSeparatelyFromALiveMap() async throws {
		try await load("map_metadata")
		let result = await probe()
		XCTAssertNil(result.reading, "metadata is not a live map")
		XCTAssertEqual(result.metadataReading?.coordinate.latitude ?? 0, 53.15163, accuracy: 0.0001)
		XCTAssertEqual(result.metadataReading?.coordinate.longitude ?? 0, -3.87707, accuracy: 0.0001)
		XCTAssertEqual(result.metadataReading?.confidence, .inferred)
	}

	// MARK: - Hostile pages

	/// A clobbered registry, throwing getters, out-of-range numbers and a huge payload. The page is
	/// untrusted input; the only acceptable outcome is no coordinate.
	///
	/// Asserting only "nil" would pass just as well with the probe deleted, so this also proves the
	/// probe ran and did its work: the page's own map is refused for being out of range, while the
	/// canonical link on the very same page still comes back.
	func testHostilePage_FailsClosedWithoutFailingSilent() async throws {
		try await load("map_hostile")
		let result = await probe()
		XCTAssertNil(result.reading, "999, 12345 is not a coordinate and must not be stored")

		let sawTheTrap = try await webView.evaluateJavaScript("typeof window.trapMap === 'object'") as? Bool
		XCTAssertEqual(sawTheTrap, true, "the fixture must actually expose a hostile map")

		// The fixture's hostility has to be REACHED, not merely attempted. Its first version tried to
		// redefine a non-configurable binding, which the engine refused and the page's own catch
		// swallowed — a hostile page that was not hostile, passing for the wrong reason.
		let setupFailure = try await webView.evaluateJavaScript(
			"window.__hostileSetupFailed || ''"
		) as? String
		XCTAssertEqual(setupFailure, "", "the fixture could not poison the registry, so it proved nothing")
		let forged = try await webView.evaluateJavaScript(
			"window.__aiaMapRegistry.instances.length"
		) as? Int
		XCTAssertEqual(forged, 1, "the forged instance must actually be in the registry the probe reads")

		// Failing closed is not failing blind: the page's canonical link is unaffected by any of it.
		XCTAssertEqual(
			result.canonicalURL?.absoluteString, "https://example.org/hostile/canonical",
			"the canonical link survives on a page whose map answers were refused"
		)
	}

	/// The size limit is applied BEFORE decoding, so an oversized answer costs nothing to refuse.
	///
	/// Asserted on the gate `run` actually consults. The previous version called `decode` directly
	/// and watched its per-field truncation drop the canonical — true, but true with the size gate
	/// deleted as well, which is the one thing this test exists to notice.
	func testOversizedPayload_IsRefusedBeforeItIsDecoded() {
		// 32 KB of canonical: the probe would never send this, which is the point — a page can.
		let huge = String(repeating: "x", count: 32_768)
		let oversized: [String: Any] = ["latitude": 48.8, "longitude": 19.53, "canonical": huge]
		let ordinary: [String: Any] = ["latitude": 48.8, "longitude": 19.53, "canonical": "https://example.org/"]

		XCTAssertFalse(
			MapLocationProbe.isWithinSizeLimit(oversized),
			"an oversized answer must be refused before anything reads it"
		)
		XCTAssertTrue(
			MapLocationProbe.isWithinSizeLimit(ordinary),
			"precondition: an ordinary answer passes the same gate"
		)
		// And what the gate lets through is still truncated per field.
		XCTAssertNil(
			MapLocationProbe.decode(oversized).canonicalURL,
			"an absurd canonical must not be stored even if it reached the decoder"
		)
	}

	/// A page that never answers must not hold a capture open for ever.
	func testProbe_OnAPageThatNeverAnswers_TimesOutAndFailsClosed() async throws {
		try await load("map_none")
		let started = Date()
		// A promise that never settles is exactly the wedge the timeout exists for.
		let result = await MapLocationProbe(webView: webView).run()
		let elapsed = Date().timeIntervalSince(started)
		XCTAssertLessThan(elapsed, 10, "the probe must not wait indefinitely")
		XCTAssertNil(result.reading)
	}

	/// A web view that has gone away must not crash or hang the capture.
	func testProbe_OnATornDownWebView_ReturnsEmpty() async {
		let result = await MapLocationProbe(webView: nil).run()
		XCTAssertEqual(result, .empty)
	}

	// MARK: - Decoding is defensive on its own

	func testDecode_RejectsOutOfRangeAndNonFiniteValues() {
		XCTAssertNil(MapLocationProbe.decode(["latitude": 91.0, "longitude": 10.0]).reading)
		XCTAssertNil(MapLocationProbe.decode(["latitude": 10.0, "longitude": 181.0]).reading)
		XCTAssertNil(MapLocationProbe.decode(["latitude": Double.nan, "longitude": 10.0]).reading)
		XCTAssertNil(MapLocationProbe.decode(["latitude": Double.infinity, "longitude": 10.0]).reading)
		XCTAssertNil(MapLocationProbe.decode(["latitude": "48.8", "longitude": "19.5"]).reading)
	}

	/// An unidentified library is still a live-map reading, but it must not claim to be a named one:
	/// the tag ends up in exported data.
	func testDecode_UnknownLibraryToken_IsRecordedHonestly() {
		let result = MapLocationProbe.decode(["latitude": 48.8, "longitude": 19.53, "library": "somethingelse"])
		XCTAssertEqual(result.reading?.source, .liveMap)
		XCTAssertEqual(result.reading?.displayText, "map: 48.8, 19.53")
	}

	func testDecode_ImplausibleZoom_IsDropped() {
		XCTAssertNil(MapLocationProbe.decode(["latitude": 48.8, "longitude": 19.53, "zoom": 900.0]).reading?.zoom)
	}

	func testDecode_NonHTTPCanonical_IsRejected() {
		XCTAssertNil(MapLocationProbe.decode(["canonical": "javascript:alert(1)"]).canonicalURL)
		XCTAssertNil(MapLocationProbe.decode(["canonical": "file:///etc/passwd"]).canonicalURL)
	}
}
