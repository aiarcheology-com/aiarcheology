//
//  MapLocationLiveSiteHarness.swift
//  MLBrowserUnitTests
//
//  AIA-0817: measuring real coverage against real mapping sites.
//
//  **Opt-in, and deliberately not part of any CI run.** It needs the network and third-party sites,
//  so a redesign, a cookie wall, a rate limit or an outage would turn the build red for reasons
//  that have nothing to do with this code — and a suite that goes red for other people's reasons
//  stops being read. Xcode Cloud minutes are paid, too.
//
//  Run it when you want a number rather than an estimate:
//
//      TEST_RUNNER_MAP_LIVE_TESTS=1 xcodebuild test-without-building \
//        -workspace MLBrowser.xcworkspace -scheme MLBrowser \
//        -destination 'platform=iOS Simulator,name=ship-ticket-runner' \
//        -only-testing:MLBrowserUnitTests/MapLocationLiveSiteHarness
//
//  Failed navigations are reported separately. Reachable sites must meet their position/URL
//  expectation; both geographic and labelled projected positions are valid evidence.
//

import UIKit
import WebKit
import XCTest
@testable import ML_Browser

final class MapLocationLiveSiteHarness: XCTestCase {

	/// What one site produced.
	private struct Outcome {
		let url: String
		let resolvedURL: String?
		let coordinate: String?
		/// The map's own position when it is not in degrees. Carried because the sites whose URL gets
		/// refreshed are precisely the national-grid ones: their evidence is here, not in
		/// `coordinate`, and a gate that ignored it accepted a refreshed URL that had been refreshed
		/// from nothing (raised in review).
		let projected: String?
		let source: String
		let libraries: [String]
		let note: String
	}

	/// What a site is expected to yield, so a regression fails instead of becoming a line in a
	/// report nobody re-reads.
	///
	/// These are not aspirations. Each was established by loading the page in a real browser and
	/// inspecting what it exposes; a site marked `.urlOnly` is one where the map is genuinely
	/// unreachable, not one nobody got round to.
	private enum Expectation {
		/// A coordinate must come back, from the live map or from the URL.
		case coordinate
		/// A live map position in its own labelled coordinate system, without inventing a projection.
		case projected(system: String)
		/// The map is in a module-scoped ESM bundle with no global and no DOM back-reference, so no
		/// injected script can reach it. Only the URL is expected.
		case urlOnly
		/// The app never rewrites its address bar, but the URL carries viewport numbers the live map
		/// can refresh — so the recorded URL must differ from the one we started with.
		case refreshedURL
	}

	private static let sites: [(url: String, expect: Expectation)] = [
		// Leaflet and friends loaded by <script>: a global exists, so the constructor trap fires.
		("https://www.freemap.sk/#map=15/47.941230/18.709545", .coordinate),
		("https://caltopo.com/map.html#ll=38.97469,-100.06486&z=12&b=r", .coordinate),
		("https://www.openstreetmap.org/#map=15/47.94123/18.70954", .coordinate),
		// Viewport in the URL, readable without any live map at all.
		("https://zbgis.skgeodesy.sk/mapka/en/teren?pos=48.800000,19.530000,12", .coordinate),
		("https://maps.nls.uk/geo/explore/side-by-side/#zoom=12&lat=53.15163&lon=-3.87707", .coordinate),
		("https://boydsmaps.com/#14.00/39.739879/-74.223193/us3depShade1/0.00/0.00", .coordinate),
		// ArcGIS web components on a national grid. Measured: the view is ready and carries a centre
		// and an extent in S-JTSK, and the page exposes no projection module — so the coordinate is
		// recorded in its own system and the frozen `extent=` is refreshed from the live view.
		("https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39&zvd=dmr5g", .refreshedURL),
		// ESM bundles with no global and no DOM back-reference. These were unreachable until the
		// `Function.prototype.bind` trap; both now resolve, confirmed in the app.
		("https://openlayers.org/en/latest/examples/simple.html", .projected(system: "Web Mercator (EPSG:3857)")),
		// A real MapLibre application rather than the documentation page, which embeds its map in an
		// iframe inside a docs shell and tests the docs site more than the viewer.
		("https://demotiles.maplibre.org/#1.5/0/0", .coordinate),
		// The URL carries only a content identifier, which must never be parsed as a place — but the
		// live map on the page is readable, and its centre is a real answer. Verified in the app:
		// this yields an `arcgis:` coordinate. The negative rule belongs to the URL tier alone, and
		// `MapURLLocationInferenceTests` is where it is enforced.
		("https://www.arcgis.com/apps/mapviewer/index.html?webmap=4931f75a164a474d91d9a3dccecee08b", .coordinate)
	]

	@MainActor
	func testLiveSites_ReportCoverage() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["MAP_LIVE_TESTS"] == "1",
			"Set MAP_LIVE_TESTS=1 to measure coverage against live sites."
		)

		var outcomes: [Outcome] = []
		var failures: [String] = []
		for site in Self.sites {
			let outcome = try await measure(site.url)
			outcomes.append(outcome)

			// A site we could not reach is not a defect in this code. Everything else is judged.
			guard outcome.note != "load failed", outcome.note != "bad URL" else { continue }

			switch site.expect {
			case .coordinate:
				if outcome.coordinate == nil {
					failures.append("\(site.url)\n    expected a coordinate, got none [\(outcome.source)]")
				}
			case let .projected(system):
				if outcome.projected?.hasPrefix(system + ": ") != true {
					failures.append("\(site.url)\n    expected a position in \(system), got \(outcome.projected ?? "none")")
				}
			case .urlOnly:
				if outcome.resolvedURL == nil {
					failures.append("\(site.url)\n    expected at least a URL, got none")
				}
			case .refreshedURL:
				// Both halves. A changed URL alone passed even when the change came from a redirect
				// and no map had answered at all, which is the one thing this expectation is for.
				if outcome.resolvedURL == site.url {
					failures.append("\(site.url)\n    expected the viewport to be refreshed from the live map, URL unchanged")
				}
				if outcome.coordinate == nil, outcome.projected == nil {
					failures.append("\(site.url)\n    URL changed but the live map gave no position — nothing could have refreshed it")
				}
			}
		}

		let report = Self.report(for: outcomes)
		// Attached rather than only printed, so the numbers survive in the result bundle.
		let attachment = XCTAttachment(string: report)
		attachment.name = "map-location-live-coverage"
		attachment.lifetime = .keepAlways
		add(attachment)
		print(report)

		// Every reachable site must still produce a URL — the ticket's floor — whatever else happened.
		for outcome in outcomes where outcome.note != "load failed" && outcome.note != "bad URL" {
			XCTAssertNotNil(outcome.resolvedURL, "\(outcome.url) produced no URL at all")
		}

		// And each site must meet the expectation established for it by inspecting the real page.
		// This is what turns the harness from a report into a gate: an adapter that stops working
		// fails here rather than quietly shrinking the coverage number.
		XCTAssertTrue(
			failures.isEmpty,
			"\(failures.count) site(s) did not meet expectations:\n" + failures.joined(separator: "\n")
		)
	}

	// MARK: - Diagnosing one page

	/// Dumps what a single page actually exposes, so a miss can be explained instead of guessed at.
	///
	///     TEST_RUNNER_MAP_LIVE_TESTS=1 TEST_RUNNER_MAP_DIAGNOSE_URL='https://…' xcodebuild test-without-building … \
	///       -only-testing:MLBrowserUnitTests/MapLocationLiveSiteHarness/testDiagnoseOnePage
	@MainActor
	func testDiagnoseOnePage() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["MAP_LIVE_TESTS"] == "1",
			"Set MAP_LIVE_TESTS=1 to diagnose a live page."
		)
		let target = ProcessInfo.processInfo.environment["MAP_DIAGNOSE_URL"]
			?? "https://ags.cuzk.cz/av/"
		guard let url = URL(string: target) else { return XCTFail("bad MAP_DIAGNOSE_URL") }

		let configuration = WKWebViewConfiguration()
		configuration.userContentController.addUserScript(
			WKUserScript(source: MapProbeScript.registry, injectionTime: .atDocumentStart, forMainFrameOnly: false)
		)
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
		try show(webView)
		defer { webView.removeFromSuperview() }
		let watcher = LoadWatcher()
		webView.navigationDelegate = watcher
		webView.load(URLRequest(url: url))
		_ = await waitForLoad(webView, watcher: watcher)
		try? await Task.sleep(for: .seconds(12))

		let dump = """
		(function () {
		  function names(re) {
		    var out = [];
		    try {
		      var keys = Object.keys(window);
		      for (var i = 0; i < keys.length; i++) { if (re.test(keys[i])) { out.push(keys[i]); } }
		    } catch (e) {}
		    return out.slice(0, 40);
		  }
		  function tagCount(sel) {
		    try { return document.querySelectorAll(sel).length; } catch (e) { return -1; }
		  }
		  var withView = [];
		  try {
		    var all = document.querySelectorAll('*');
		    for (var i = 0; i < all.length && withView.length < 12; i++) {
		      try { if (all[i].view && typeof all[i].view === 'object') { withView.push(all[i].tagName + '.' + all[i].className); } } catch (e) {}
		    }
		  } catch (e) {}
		  // What the ArcGIS view itself actually holds — the step that keeps coming back empty.
		  var views = [];
		  try {
		    var comps = document.querySelectorAll('arcgis-map, arcgis-scene');
		    for (var v = 0; v < comps.length; v++) {
		      var view = comps[v].view;
		      if (!view) { views.push({ tag: comps[v].tagName, view: 'none' }); continue; }
		      var c = view.center;
		      views.push({
		        tag: comps[v].tagName,
		        ready: view.ready,
		        hasCenter: !!c,
		        lat: c ? c.latitude : null,
		        lon: c ? c.longitude : null,
		        x: c ? c.x : null,
		        y: c ? c.y : null,
		        wkid: c && c.spatialReference ? (c.spatialReference.wkid || c.spatialReference.latestWkid) : null,
		        zoom: view.zoom,
		        containerConnected: view.container ? view.container.isConnected : null,
		        containerInDocument: view.container ? document.contains(view.container) : null
		      });
		    }
		  } catch (e) { views.push({ error: String(e) }); }

		  var reg = null;
		  try { reg = window.__aiaMapRegistry ? {n: window.__aiaMapRegistry.instances.length, libs: window.__aiaMapRegistry.libraries} : null; } catch (e) {}
		  return JSON.stringify({
		    href: location.href,
		    registry: reg,
		    views: views,
		    hasRequire: typeof window.require,
		    hasDefine: typeof window.define,
		    hasEsriNS: typeof window.__esri,
		    hasEsri: typeof window.esri,
		    hasL: typeof window.L,
		    hasOl: typeof window.ol,
		    arcgisMapEls: tagCount('arcgis-map, arcgis-scene'),
		    esriViewEls: tagCount('.esri-view'),
		    canvases: tagCount('canvas'),
		    title: document.title,
		    iframes: tagCount('iframe'),
		    elementsWithView: withView,
		    esriKeys: names(/esri|arcgis/i),
		    mapKeys: names(/^(map|view|app|viewer)/i)
		  }, null, 1);
		}())
		"""
		let raw = try? await webView.evaluateJavaScript(dump)
		var text = (raw as? String) ?? "no result"

		// The dump says what the page exposes; this says what we managed to make of it.
		let probe = await MapLocationProbe(webView: webView).run()
		let location = MapLocationResolver.resolve(url: webView.url, probe: probe)
		text += """

		--- resolved ---
		url:    \(location.sourceURL?.absoluteString ?? "NONE")
		coord:  \(location.reading.map { MapLocationReading.formattedPair($0.coordinate) } ?? "none")
		projected: \(location.projectedText ?? "none")
		source: \(location.reading?.source.rawValue ?? "none")
		libs:   \(probe.libraries.joined(separator: ", "))
		"""
		print("=== DIAGNOSTIC for \(target) ===")
		print(text)
		let attachment = XCTAttachment(string: "\(target)\n\n\(text)")
		attachment.name = "map-page-diagnostic"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	/// Map SDKs use animation frames and visibility to finish creating their views. An offscreen
	/// WKWebView can finish navigation while never running that work.
	@MainActor
	func testVisibleWebView_RunsAnimationFrames() async throws {
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
		try show(webView)
		defer { webView.removeFromSuperview() }
		let watcher = LoadWatcher()
		webView.navigationDelegate = watcher
		webView.loadHTMLString("<html><body><canvas></canvas></body></html>", baseURL: nil)
		let loaded = await waitForLoad(webView, watcher: watcher)
		XCTAssertTrue(loaded)
		try await webView.evaluateJavaScript("requestAnimationFrame(function () { window.__rendered = true; });")
		let deadline = Date().addingTimeInterval(5)
		while Date() < deadline {
			if try await webView.evaluateJavaScript("window.__rendered === true") as? Bool == true { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		XCTFail("The visible live-map harness must receive animation frames.")
	}

	@MainActor
	private func show(_ webView: WKWebView) throws {
		let window = try XCTUnwrap(
			UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
				.flatMap(\.windows).first(where: \.isKeyWindow),
			"Live map coverage requires a visible test-host window."
		)
		window.addSubview(webView)
		webView.layoutIfNeeded()
	}

	// MARK: - One site

	@MainActor
	private func measure(_ site: String) async throws -> Outcome {
		guard let url = URL(string: site) else {
			return Outcome(url: site, resolvedURL: nil, coordinate: nil, projected: nil, source: "-", libraries: [], note: "bad URL")
		}

		let configuration = WKWebViewConfiguration()
		configuration.userContentController.addUserScript(
			WKUserScript(source: MapProbeScript.registry, injectionTime: .atDocumentStart, forMainFrameOnly: false)
		)
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
		try show(webView)
		defer { webView.removeFromSuperview() }
		let watcher = LoadWatcher()
		webView.navigationDelegate = watcher
		webView.load(URLRequest(url: url))

		guard await waitForLoad(webView, watcher: watcher) else {
			return Outcome(url: site, resolvedURL: nil, coordinate: nil, projected: nil, source: "-", libraries: [], note: "load failed")
		}
		// Map libraries initialise after `didFinish`, and a tile fetch or two later. This is the one
		// place a fixed settle is honest: a third-party site owes us no readiness signal. Eight
		// seconds because the heavyweight GIS apps -- ArcGIS templates especially -- are still
		// wiring themselves up well after the document finishes.
		try? await Task.sleep(for: .seconds(8))

		let probe = await MapLocationProbe(webView: webView).run()
		let location = MapLocationResolver.resolve(url: webView.url ?? url, probe: probe)

		return Outcome(
			url: site,
			resolvedURL: location.sourceURL?.absoluteString,
			coordinate: location.reading.map { MapLocationReading.formattedPair($0.coordinate) },
			projected: location.projectedText,
			source: location.reading?.source.rawValue ?? "none",
			libraries: probe.libraries,
			note: location.corroborated ? "corroborated" : ""
		)
	}

	/// Watches one load, so a failure is reported as a failure.
	///
	/// `isLoading == false && url != nil` was the old test, and a *failed* provisional navigation
	/// satisfies both — WebKit keeps the requested URL on the view — so an outage was reported as a
	/// site that loaded and then answered nothing, which reads as a broken adapter (raised in review).
	@MainActor
	private final class LoadWatcher: NSObject, WKNavigationDelegate {
		private(set) var finished = false
		private(set) var failed = false

		nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			MainActor.assumeIsolated { finished = true }
		}

		nonisolated func webView(
			_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
		) {
			MainActor.assumeIsolated { failed = true }
		}

		nonisolated func webView(
			_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
		) {
			MainActor.assumeIsolated { failed = true }
		}
	}

	@MainActor
	private func waitForLoad(_ webView: WKWebView, watcher: LoadWatcher) async -> Bool {
		let deadline = Date().addingTimeInterval(30)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(250))
			if watcher.failed { return false }
			if watcher.finished, webView.isLoading == false, webView.url != nil { return true }
		}
		return false
	}

	// MARK: - Report

	private static func report(for outcomes: [Outcome]) -> String {
		let reachable = outcomes.filter { $0.note != "load failed" && $0.note != "bad URL" }
		let located = reachable.filter { $0.coordinate != nil }
		let exact = reachable.filter {
			MapLocationSource(rawValue: $0.source)?.confidence == .exact
		}

		var lines: [String] = []
		lines.append("AIA-0817 live coverage — \(Date())")
		lines.append(String(repeating: "=", count: 72))
		for outcome in outcomes {
			lines.append("")
			lines.append(outcome.url)
			lines.append("  url:    \(outcome.resolvedURL ?? "NONE")")
			lines.append("  coord:  \(outcome.coordinate ?? "none")  [\(outcome.source)] \(outcome.note)")
			if let projected = outcome.projected { lines.append("  projected: \(projected)") }
			if outcome.libraries.isEmpty.not {
				lines.append("  libs:   \(outcome.libraries.joined(separator: ", "))")
			}
		}
		lines.append("")
		lines.append(String(repeating: "-", count: 72))
		lines.append("reachable:            \(reachable.count)/\(outcomes.count)")
		lines.append("URL recorded:         \(reachable.filter { $0.resolvedURL != nil }.count)/\(reachable.count)")
		lines.append("coordinate resolved:  \(located.count)/\(reachable.count)")
		lines.append("  of those, exact:    \(exact.count) (live map)")
		lines.append("  of those, inferred: \(located.count - exact.count) (URL or metadata)")
		return lines.joined(separator: "\n")
	}
}
