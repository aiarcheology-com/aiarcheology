//
//  MapLocationResolver.swift
//  AI Archeology
//
//  Combining what the live map said, what the URL said, and what the page's metadata said (AIA-0817).
//

import Foundation
import WebKit

/// Resolves everything known about the page a finding was captured on.
///
/// The tiers are not alternatives tried until one answers — they are independent witnesses, and
/// where two agree that agreement is itself worth recording. This is the "test the parsers and
/// choose" step made literal: the probes are run and compared rather than guessed between.
///
/// Order of preference:
/// 1. a live map reporting its own centre (`.exact`);
/// 2. a standard viewport grammar in the URL (`.inferred`);
/// 3. `og:`/`geo.position`/JSON-LD metadata (`.inferred`).
///
/// A URL is always returned, whatever the tiers do. That is the ticket's floor: the worst outcome
/// is the page's own address with no coordinate, never no record at all.
@MainActor
enum MapLocationResolver {

	/// How far apart two independent readings may be and still count as agreeing.
	///
	/// Generous on purpose. The URL usually lags the live map slightly — a site debounces its
	/// `replaceState`, or rounds the value it writes — so demanding equality would report a
	/// conflict on almost every site that works correctly. About 100 m of latitude: close enough to
	/// mean "the same view", far enough that a transposed or stale pair does not sneak through.
	static let corroborationTolerance = 0.001

	/// Resolves without touching the web view. Used by tests, by the live harness, and whenever a
	/// probe is not available.
	static func resolve(
		url: URL?,
		probe: MapLocationProbe.Result = .empty,
		pageMaintainsItsURL: Bool = true
	) -> MapPageLocation {
		let urlReading = url.flatMap(MapURLLocationInference.reading(from:))

		// Preference order is by confidence, not by tier number: a live map beats text, and text
		// beats metadata that may describe the page's subject rather than its viewport.
		// A live map that reports a projected position still knows where it is looking, and the URL
		// may be describing somewhere the user left minutes ago. So when the map answers at all —
		// in degrees or in its own grid — it wins; text is only consulted when no map answered.
		let liveProjected = projectedFromProbe(probe)
		let chosen = probe.reading ?? (liveProjected == nil ? (urlReading ?? probe.metadataReading) : nil)

		// Any two independent witnesses agreeing, not only the live map and the URL. The URL and the
		// page's own metadata are as independent of each other as either is of the map — a page that
		// publishes `og:latitude` did not derive it from its own query string — and reporting that
		// pair as uncorroborated understated exactly the case where no live map could be read
		// (raised in review).
		// Every PAIR. Comparing the first witness against the rest misses the case the sentence above
		// promises: a live map that disagrees with a URL and metadata which agree with each other
		// (raised in review).
		let witnesses = [probe.reading, urlReading, probe.metadataReading].compactMap { $0?.coordinate }
		let corroborated = witnesses.indices.contains { first in
			witnesses[(first + 1)...].contains { agree(witnesses[first], $0) }
		}

		// An app that never rewrites its address bar leaves the URL frozen at whatever view the user
		// arrived with, so every finding on that site records the same place. When the live map can
		// supply current numbers for a viewport parameter the URL already carries, use them: the
		// result is the same link the app's own "copy link to this view" button produces.
		// The live reading is offered too: a `#Z/LAT/LON` hash is degrees by definition, so it can
		// only be refreshed from a geographic coordinate, not from the map's native units.
		let live = probe.reading
		// A fragment viewport is only refreshed for a page that maintains its own URL. One that never
		// rewrites its hash is not using it as state, and almost certainly does not read it on load
		// either — writing a viewport there yields a link that looks precise and opens on the
		// default view. Query parameters are different: those are what a site's own share action
		// produces, and refreshing one is how a frozen `extent=` becomes current.
		let refreshedURL = url.flatMap {
			MapURLViewportRefresh.refreshed(
				url: $0,
				extent: probe.nativeExtent,
				center: probe.nativeCenter,
				geographic: live.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
				zoom: live?.zoom,
				mayRefreshFragment: pageMaintainsItsURL
			)
		}

		// Recorded whenever the map gave no degrees, whether or not text offered some.
		let projectedText = chosen == nil ? liveProjected : nil

		return MapPageLocation(
			sourceURL: refreshedURL ?? url,
			// `urlReading` doubles as the "does this URL carry a viewport" answer, so the URL is
			// parsed once rather than again inside the canonical check.
			canonicalURL: canonical(probe.canonicalURL, for: url, urlCarriesViewport: urlReading != nil),
			reading: chosen,
			projectedText: projectedText,
			corroborated: corroborated
		)
	}

	/// Resolves against a live web view: runs the probe, then combines.
	///
	/// - Parameter mayProbe: whether a given page may be questioned at all (AIA-0821). When it says
	///   no, the URL tiers still run — reading a coordinate out of an address the app already holds
	///   cannot cost anyone the page — but no JavaScript is executed in the user's document.
	///
	///   A closure rather than a `Bool`, and asked again by the probe before each execution: the
	///   probe can wait seconds and the page can move during them, so a single answer taken against
	///   the capture URL would not describe the document the script would actually run in.
	///
	///   The decision belongs to the caller, which owns the arming policy; making it here would mean
	///   this type reaching for global state to answer a question it is not the authority on. It
	///   deliberately has **no default** — a default of "yes" would let the next caller run
	///   JavaScript in the user's page with the switch off, by saying nothing.
	static func resolve(
		url: URL?,
		webView: WKWebView?,
		frames: [WKFrameInfo] = [],
		pageMaintainsItsURL: Bool = true,
		mayProbe: @escaping @MainActor (URL?) -> Bool
	) async -> MapPageLocation {
		let probe = mayProbe(url)
			? await MapLocationProbe(webView: webView, mayProbe: mayProbe).runAcrossFrames(frames)
			: .empty
		return resolve(url: url, probe: probe, pageMaintainsItsURL: pageMaintainsItsURL)
	}

	/// The live map's own position, named by its coordinate system, when it reports no degrees.
	private static func projectedFromProbe(_ probe: MapLocationProbe.Result) -> String? {
		guard probe.reading == nil, let centre = probe.nativeCenter, centre.count == 2,
		      probe.nativeWkid.map(MapCoordinateReferenceSystem.isGeographic) != true
		else { return nil }
		return "\(MapCoordinateReferenceSystem.label(for: probe.nativeWkid)): "
			+ "\(MapLocationReading.formatted(centre[0])), \(MapLocationReading.formatted(centre[1]))"
	}

	static func agree(_ first: MapCoordinate, _ second: MapCoordinate) -> Bool {
		abs(first.latitude - second.latitude) <= corroborationTolerance
			&& abs(first.longitude - second.longitude) <= corroborationTolerance
	}

	/// A canonical link is only worth keeping when it does not throw away the view the user found.
	///
	/// Map apps routinely declare a canonical URL pointing at their landing page. Recording that
	/// alongside a captured URL whose query or fragment holds the viewport would offer a reader the
	/// weaker of the two links, so it is dropped in exactly that case.
	private static func canonical(_ canonical: URL?, for sourceURL: URL?, urlCarriesViewport: Bool) -> URL? {
		guard let canonical else { return nil }
		guard let sourceURL else { return canonical }
		if canonical == sourceURL { return nil }
		return urlCarriesViewport ? nil : canonical
	}
}
