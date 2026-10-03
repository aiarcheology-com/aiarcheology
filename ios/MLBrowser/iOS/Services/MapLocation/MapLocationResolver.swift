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
	/// - Parameter pageMaintainsItsURL: whether this page's URL is known to be its own — seen
	///   rewritten, or opened at an address the app wrote (AIA-0875). Defaults to `false`, the state
	///   before anything is known. It defaults that way deliberately. `true` now skips the whole viewport refresh
	///   (AIA-0871), so a default of `true` would silently disable AIA-0817 for every caller that
	///   forgot the argument — including `MapLocationLiveSiteHarness`, whose entire job is to show
	///   what a frozen-URL site records. Production never relies on this: `BrowserState`
	///   passes its `pageMaintainsItsURL` explicitly.
	static func resolve(
		url: URL?,
		probe: MapLocationProbe.Result = .empty,
		pageMaintainsItsURL: Bool = false
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
		// AIA-0871: an app that rewrites its own address as the user pans has ALREADY published this
		// viewport, and `BrowserState.urlChanged` follows those same-document rewrites into
		// `committedURL` — so the URL in hand is the app's own and is already current. Refreshing it
		// substitutes our reading for the app's own numbers, and the two need not mean the same
		// thing: `unitsAgree` only separates degrees from not-degrees, so a map whose view is held
		// in one projection while its URL is written in another would pass unchallenged, and so
		// would a correct pair in the opposite axis order. A finding taken on a Bavarian atlas
		// recorded a `?c=` pointing into the Baltic; which of those produced it was never
		// diagnosed against the site's source, and the rule below does not depend on the answer.
		//
		// The refresh exists for the opposite page (AIA-0817): one that never touches its address
		// bar, whose URL stays frozen at the view the user arrived with, so that every finding on
		// the site records the same place. Only there is our reading better than what is in hand.
		//
		// AIA-0875: `pageMaintainsItsURL` is more than "seen rewriting its address", which is false
		// before the first pan. `BrowserState.pageMaintainsItsURL` also counts a page reopened by
		// Reopen Last Page at its saved address, a reload of a page that kept its URL, and an address
		// change made while the document was still loading. Still not covered, and still refreshed
		// before the first pan: a pasted share link, Back/Forward, and a reload onto a rebuilt web
		// view. A guard inside the refresh itself would close those too, but cannot tell a same-CRS
		// frozen page (the AIA-0817 case) from a mismatched one without knowing the URL's CRS.
		//
		// Consequence worth stating: `refreshedFragment` required `pageMaintainsItsURL`, which is
		// now exactly the case that skips the refresh, so that path is unreachable from here. The
		// named-parameter branch inside `replacing()` still handles a `#center=x,y` fragment for a
		// frozen page. The capability is kept and directly tested — see AIA-0871 before wiring it up.
		let refreshedURL: URL? = pageMaintainsItsURL ? nil : url.flatMap {
			MapURLViewportRefresh.refreshed(
				url: $0,
				extent: probe.nativeExtent,
				center: probe.nativeCenter,
				geographic: live.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
				zoom: live?.zoom,
				mayRefreshFragment: false
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
		// Same default, same reason, as the pure overload above.
		pageMaintainsItsURL: Bool = false,
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
