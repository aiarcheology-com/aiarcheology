//
//  MapLocationProbe.swift
//  AI Archeology
//
//  Runs the map probe against a live web view and turns its answer into validated Swift (AIA-0817).
//

import Foundation
import WebKit

/// Asks a page's live map where it is looking.
///
/// Everything the page returns is untrusted input. A map site can be hostile, broken, or simply
/// wrong, and the registry global the probe reads is page-visible and page-clobberable — so the
/// result is re-validated here rather than believed. The worst case is a wrong coordinate in an
/// editable field, which is why "the page can lie" is an acceptable risk and "the page can make us
/// evaluate its string" would not be.
///
/// `@MainActor` despite living under `Services/`, where AGENTS.md §7 says services stay off the
/// main actor: `WKWebView` and `callAsyncJavaScript` are main-bound, so there is nothing to move
/// off it. The Harmonize rule only scans `*Service`-suffixed declarations, so this passes without
/// being examined — recorded here so the exemption is a decision rather than an accident.
@MainActor
struct MapLocationProbe {

	/// What the probe found, before it is combined with the URL tiers.
	struct Result: Equatable, Sendable {
		let reading: MapLocationReading?
		let canonicalURL: URL?
		/// Coordinates from `og:`/`geo.position` metadata, kept apart from the live-map reading
		/// because they describe whatever the page is *about*, which is often a business or an
		/// article subject rather than the current viewport.
		let metadataReading: MapLocationReading?
		/// Libraries the registry saw, whether or not a centre could be read. Diagnostic only —
		/// this is what tells us which adapter to write next.
		let libraries: [String]
		/// The viewport in the map's OWN coordinate system, unconverted.
		///
		/// Not a location, and never stored as one. It exists so a URL that already carries viewport
		/// numbers can have them refreshed from the live view — the only way an app that never
		/// rewrites its address bar can still yield a URL that reopens the exact view.
		let nativeExtent: [Double]?
		let nativeCenter: [Double]?
		/// The EPSG code the map's own coordinates are in, when it says.
		let nativeWkid: Int?

		static let empty = Result(
			reading: nil, canonicalURL: nil, metadataReading: nil, libraries: [],
			nativeExtent: nil, nativeCenter: nil, nativeWkid: nil
		)
	}

	/// How long to wait for the page before giving up on it.
	///
	/// This abandons a *result*; it does not stop the page's JavaScript, which no native timeout
	/// can do. That is why ``MapProbeScript/probe`` carries its own cooperative deadline — this is
	/// the outer backstop for a page that never returns at all.
	///
	/// Comfortably longer than the script's own budget, which now includes waiting for an ArcGIS
	/// view to report itself ready. Cutting the script off mid-wait would reintroduce exactly the
	/// empty result this was raised to fix.
	private static let timeout: Duration = .milliseconds(4000)

	/// Refuses an implausibly large payload before decoding rather than after.
	///
	/// Per-field caps applied after parsing would already have paid the cost of parsing whatever
	/// the page sent.
	private static let maximumPayloadBytes = 16_384

	/// How long all child frames together may take before the capture stops waiting.
	private static let frameBudgetSeconds: TimeInterval = 6

	/// The web view to interrogate. Weak: the probe must never keep a torn-down view alive.
	private weak var webView: WKWebView?

	/// Whether the page currently on screen may be questioned (AIA-0821).
	///
	/// Asked again immediately before each execution rather than decided once by the caller. The
	/// probe can wait seconds — four per frame, six across frames — and the page can move during
	/// them. A decision made against the capture URL would let a drift onto a host the breaker has
	/// disarmed be met with JavaScript anyway, which is the one thing that host was disarmed to
	/// prevent (raised in review).
	private let mayProbe: @MainActor (URL?) -> Bool

	init(webView: WKWebView?, mayProbe: @escaping @MainActor (URL?) -> Bool = { _ in true }) {
		self.webView = webView
		self.mayProbe = mayProbe
	}

	/// Asks the main frame, then any child frame that announced itself, stopping at the first real
	/// answer.
	///
	/// Iframed maps are common — documentation examples, portal embeds, viewer products — and the
	/// main frame of such a page contains no map at all, so a main-frame-only probe reports nothing
	/// while the map sits one frame down.
	func runAcrossFrames(_ frames: [WKFrameInfo]) async -> Result {
		let main = await run()
		if main.reading != nil || main.nativeCenter != nil { return main }

		// Sequential, but under one shared budget. Each frame can cost the full timeout, so a portal
		// with several frames would otherwise hold a finding capture open for the sum of them — and
		// the user is waiting for a sheet the whole time. (A task group would let them overlap, but
		// `WKFrameInfo` is not `Sendable`, and smuggling it across an isolation boundary to save a
		// second on a rare page is not a trade worth making.)
		// The budget is a deadline for the whole loop AND a cap on each probe inside it. Checking it
		// only before starting a frame was not enough: a frame begun at 5.9s still ran its full
		// four-second timeout, so a six-second budget could take nearly ten (raised in review, twice).
		let deadline = Date().addingTimeInterval(Self.frameBudgetSeconds)
		for frame in frames {
			let remaining = deadline.timeIntervalSinceNow
			guard remaining > 0 else { break }
			let result = await run(in: frame, timeout: min(Self.timeout, .seconds(remaining)))
			// A native extent alone is an answer. It cannot prefill a coordinate, but it is what the
			// URL viewport refresh writes back, and discarding it left an iframed map that reports
			// only an extent unable to update the address it came from (raised in review).
			if result.reading != nil || result.nativeCenter != nil || result.nativeExtent != nil {
				return result
			}
		}

		// Nothing located anywhere; keep the main frame's answer, which still carries its canonical
		// link and library diagnostics.
		return main
	}

	/// Runs the probe in the page content world, in the given frame (or the main frame).
	///
	/// The page world is required — the registry and the libraries live on the page's own `window`,
	/// which an isolated world cannot see. It also matches what the app already does elsewhere.
	func run(in frame: WKFrameInfo? = nil, timeout: Duration = Self.timeout) async -> Result {
		// The kill switch removes the probe as well as the injection, so a bisecting run behaves
		// exactly as the app did before this feature rather than merely finding nothing.
		guard AppEnvironment.isMapLocationParserDisabled.not else { return .empty }
		guard let webView else { return .empty }
		// Re-asked against the page as it is NOW, not as it was when the capture began.
		guard mayProbe(webView.url) else { return .empty }

		// A one-shot continuation, resumed by whichever of the two arrives first.
		//
		// Deliberately not a cancelling task group: cancelling a Swift task cannot stop JavaScript
		// that WebKit is already running, so a "cancel" would be theatre. What actually needs to
		// happen is that the capture stops *waiting* — the page may keep working, and its result is
		// simply abandoned. The script's own cooperative deadline is what limits the page-side cost.
		return await withCheckedContinuation { continuation in
			let gate = ResumeOnce(continuation)

			let timer = Task { @MainActor in
				try? await Task.sleep(for: timeout)
				gate.finish(.empty)
			}

			Task { @MainActor in
				// Cancelled on every exit below, so a probe that answers in 200ms does not leave a
				// task sleeping for the remaining seconds. `ResumeOnce` already made a late timeout
				// harmless, but harmless is not free: `runAcrossFrames` starts one of these per frame
				// (raised in review).
				defer { timer.cancel() }
				// Asked again HERE, immediately before WebKit is called. The check above happens
				// before this task is scheduled, and main-actor isolation does not preserve a
				// decision across a scheduling boundary: the switch can be turned off, or the page
				// can reach a disarmed host, in between (raised in review).
				guard mayProbe(webView.url) else {
					gate.finish(.empty)
					return
				}
				do {
					let raw = try await webView.callAsyncJavaScript(
						MapProbeScript.probe,
						arguments: [:],
						in: frame,
						contentWorld: .page
					)
					guard let payload = raw as? [String: Any], Self.isWithinSizeLimit(payload) else {
						gate.finish(.empty)
						return
					}
					gate.finish(Self.decode(payload))
				} catch {
					// A page that threw, a frame that went away, or a torn-down web view. Fail
					// closed: a finding with no coordinate is correct, one with a guess is not.
					gate.finish(.empty)
				}
			}
		}
	}

	/// Guarantees a continuation is resumed exactly once, whichever of the probe and the timeout
	/// gets there first. Resuming twice is undefined behaviour, not a recoverable mistake.
	@MainActor
	private final class ResumeOnce {
		private var continuation: CheckedContinuation<Result, Never>?

		init(_ continuation: CheckedContinuation<Result, Never>) {
			self.continuation = continuation
		}

		func finish(_ result: Result) {
			guard let pending = continuation else { return }
			continuation = nil
			pending.resume(returning: result)
		}
	}

	// MARK: - Decoding

	/// A cheap upper bound on how much the page sent back.
	///
	/// Internal rather than private so a test can put a real payload through the gate itself. The
	/// test that was here asserted `decode`'s own per-field truncation instead and would have stayed
	/// green with the gate deleted (raised in review).
	static func isWithinSizeLimit(_ payload: [String: Any]) -> Bool {
		guard JSONSerialization.isValidJSONObject(payload),
		      let data = try? JSONSerialization.data(withJSONObject: payload)
		else { return false }
		return data.count <= maximumPayloadBytes
	}

	static func decode(_ payload: [String: Any]) -> Result {
		let libraries = (payload["libraries"] as? [Any] ?? [])
			.compactMap { $0 as? String }
			.prefix(12)
			.map { String($0.prefix(40)) }

		var reading: MapLocationReading?
		if let source = finiteDouble(payload["latitude"]),
		   let longitude = finiteDouble(payload["longitude"]),
		   let coordinate = MapCoordinate(latitude: source, longitude: longitude) {
			reading = MapLocationReading(
				coordinate: coordinate,
				zoom: plausibleZoom(payload["zoom"]),
				source: library(from: payload["library"]),
				rawText: nil
			)
		}

		// A coordinate the page was showing. Parsed with the same tolerant reader the free-text GPS
		// field uses, so the many written forms (`48.8, 19.5`, `N48.8 E19.5`, degree symbols) are all
		// accepted — and stored exactly as the page wrote it.
		var displayedReading: MapLocationReading?
		if let shown = payload["displayedCoordinate"] as? String, shown.count <= 60,
		   let coordinate = CoordinateText.parse(shown) {
			displayedReading = MapLocationReading(coordinate: coordinate, source: .displayedText, rawText: shown)
		}

		var metadataReading: MapLocationReading?
		if let latitude = finiteDouble(payload["metaLatitude"]),
		   let longitude = finiteDouble(payload["metaLongitude"]),
		   let coordinate = MapCoordinate(latitude: latitude, longitude: longitude) {
			metadataReading = MapLocationReading(coordinate: coordinate, source: .pageMetadata)
		}

		var canonical: URL?
		if let text = payload["canonical"] as? String, text.count <= 2000,
		   let url = URL(string: text), let scheme = url.scheme?.lowercased(),
		   scheme == "http" || scheme == "https" {
			canonical = url
		}

		return Result(
			reading: reading,
			canonicalURL: canonical,
			// The displayed readout first: it is rendered from the current viewport, whereas `og:`
			// and JSON-LD describe what the page is *about* and are frequently a different place
			// entirely. Having these the wrong way round meant a page carrying both prefilled the
			// weaker answer while the better one sat unused.
			metadataReading: displayedReading ?? metadataReading,
			libraries: Array(libraries),
			nativeExtent: numbers(payload["nativeExtent"], count: 4),
			nativeCenter: numbers(payload["nativeCenter"], count: 2),
			nativeWkid: (payload["nativeWkid"] as? NSNumber).map { $0.intValue }
		)
	}

	/// Maps the script's library token onto a source case.
	///
	/// An unrecognised token still counts as a live-map reading — a duck-typed hit on a library
	/// nobody has written an adapter for is exactly the case worth keeping — but it is recorded as
	/// ``MapLocationSource/liveMap`` rather than guessed at. Naming a library we did not identify
	/// would put a false claim into data that is persisted, exported and shared.
	private static func library(from value: Any?) -> MapLocationSource {
		switch value as? String {
		case "leaflet": return .leaflet
		case "openlayers": return .openLayers
		case "openlayers2": return .openLayers2
		case "maplibre": return .mapLibre
		case "arcgis": return .arcGIS
		case "googlemaps": return .googleMaps
		case "cesium": return .cesium
		default: return .liveMap
		}
	}

	/// A fixed-length array of finite numbers, or nothing. The page supplies these, so a short,
	/// long, or non-numeric answer is simply not a viewport.
	private static func numbers(_ value: Any?, count: Int) -> [Double]? {
		guard let raw = value as? [Any], raw.count == count else { return nil }
		let parsed = raw.compactMap(finiteDouble)
		return parsed.count == count ? parsed : nil
	}

	private static func finiteDouble(_ value: Any?) -> Double? {
		guard let number = value as? Double ?? (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
		return number
	}

	private static func plausibleZoom(_ value: Any?) -> Double? {
		guard let zoom = finiteDouble(value), (0...24).contains(zoom) else { return nil }
		return zoom
	}
}
