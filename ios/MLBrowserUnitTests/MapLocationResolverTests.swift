//
//  MapLocationResolverTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: which witness wins, when they agree, and what survives when they all fail.
//

import XCTest
@testable import ML_Browser

@MainActor
final class MapLocationResolverTests: XCTestCase {

	private func coordinate(_ latitude: Double, _ longitude: Double) -> MapCoordinate {
		guard let value = MapCoordinate(latitude: latitude, longitude: longitude) else {
			preconditionFailure("test fixture is not a valid coordinate")
		}
		return value
	}

	private func probe(
		live: MapCoordinate? = nil,
		metadata: MapCoordinate? = nil,
		canonical: String? = nil,
		nativeExtent: [Double]? = nil,
		nativeCenter: [Double]? = nil,
		nativeWkid: Int? = nil
	) -> MapLocationProbe.Result {
		MapLocationProbe.Result(
			reading: live.map { MapLocationReading(coordinate: $0, source: .leaflet) },
			canonicalURL: canonical.flatMap(URL.init(string:)),
			metadataReading: metadata.map { MapLocationReading(coordinate: $0, source: .pageMetadata) },
			libraries: [],
			nativeExtent: nativeExtent,
			nativeCenter: nativeCenter,
			nativeWkid: nativeWkid
		)
	}

	private func url(_ string: String) -> URL {
		guard let value = URL(string: string) else { preconditionFailure("bad fixture URL") }
		return value
	}

	// MARK: - The URL is always recorded

	/// The ticket's floor. CUZK never writes its viewport, and if the probe finds nothing either,
	/// the finding must still carry the page's own address.
	func testURL_IsAlwaysCarried_EvenWithNothingElse() {
		let location = MapLocationResolver.resolve(url: url("https://ags.cuzk.gov.cz/av/"))
		XCTAssertEqual(location.sourceURL?.absoluteString, "https://ags.cuzk.gov.cz/av/")
		XCTAssertNil(location.reading)
		XCTAssertNil(location.gpsPrefill)
	}

	func testNoURLAtAll_IsRepresentable() {
		let location = MapLocationResolver.resolve(url: nil)
		XCTAssertNil(location.sourceURL)
		XCTAssertNil(location.reading)
	}

	// MARK: - Preference order

	/// A running map beats text about a map. The URL here says somewhere else entirely; the live
	/// reading must win, because it is what the user was actually looking at.
	func testLiveMap_BeatsTheURL() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/10.0/10.0"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertEqual(location.reading?.source, .leaflet)
		XCTAssertEqual(location.reading?.confidence, .exact)
		XCTAssertEqual(location.reading?.coordinate.latitude ?? 0, 47.941230, accuracy: 0.0000001)
	}

	func testURL_BeatsPageMetadata() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/47.941230/18.709545"),
			probe: probe(metadata: coordinate(10, 10))
		)
		XCTAssertEqual(location.reading?.source, .urlHashPath)
	}

	/// Metadata is the last resort: it often describes what a page is *about* rather than where it
	/// is looking, which is why it never outranks anything.
	func testPageMetadata_IsUsedOnlyWhenNothingElseAnswers() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/about"),
			probe: probe(metadata: coordinate(53.15163, -3.87707))
		)
		XCTAssertEqual(location.reading?.source, .pageMetadata)
		XCTAssertEqual(location.reading?.confidence, .inferred)
	}

	// MARK: - Corroboration

	func testCorroborated_WhenTheMapAndTheURLAgree() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/47.941230/18.709545"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertTrue(location.corroborated)
	}

	/// A site that debounces its `replaceState` writes a slightly stale value. That is a working
	/// site, not a conflict, so the tolerance has to absorb it.
	func testCorroborated_ToleratesASlightlyStaleURL() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/47.941100/18.709500"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertTrue(location.corroborated)
	}

	/// Disagreement keeps the live map and says so, rather than averaging two readings or picking
	/// the more convenient one.
	func testConflict_KeepsTheLiveMapAndIsNotMarkedCorroborated() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/10.000000/10.000000"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertFalse(location.corroborated)
		XCTAssertEqual(location.reading?.coordinate.latitude ?? 0, 47.941230, accuracy: 0.0000001)
	}

	/// A transposed pair is exactly what corroboration should refuse to bless.
	func testTransposedURL_DoesNotCorroborateALiveReading() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/18.709545/47.941230"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertFalse(location.corroborated)
	}

	func testCorroboration_NeedsTwoIndependentWitnesses() {
		let liveOnly = MapLocationResolver.resolve(
			url: url("https://example.org/plain"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertFalse(liveOnly.corroborated, "one witness cannot corroborate itself")
	}

	// MARK: - Canonical URL

	/// The trap this guards: a map app declaring a canonical link to its landing page. Offering
	/// that beside a URL that pins the exact view would hand a reader the weaker of the two.
	func testCanonical_IsDroppedWhenTheCapturedURLHoldsTheViewport() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/#map=15/47.941230/18.709545"),
			probe: probe(canonical: "https://example.org/")
		)
		XCTAssertNil(location.canonicalURL)
	}

	func testCanonical_IsKeptWhenTheCapturedURLHoldsNoViewport() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/dataset?id=7"),
			probe: probe(canonical: "https://example.org/dataset/7")
		)
		XCTAssertEqual(location.canonicalURL?.absoluteString, "https://example.org/dataset/7")
	}

	func testCanonical_IdenticalToTheSourceURL_IsNotDuplicated() {
		let location = MapLocationResolver.resolve(
			url: url("https://example.org/page"),
			probe: probe(canonical: "https://example.org/page")
		)
		XCTAssertNil(location.canonicalURL)
	}

	// MARK: - Refreshing a frozen viewport

	/// The case the ticket was opened for: an app that never rewrites its address bar, so the URL
	/// keeps whatever view the user arrived with and every finding records the same place.
	func testStaleExtentInTheURL_IsRefreshedFromTheLiveMap() {
		let stale = url("https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39&zvd=dmr5g")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(nativeExtent: [-820000, -1025000, -815000, -1020000])
		)
		let refreshed = location.sourceURL?.absoluteString ?? ""
		XCTAssertTrue(refreshed.contains("extent=-820000,-1025000,-815000,-1020000"), refreshed)
		XCTAssertTrue(refreshed.contains("zvd=dmr5g"), "the app's other parameters must survive")
	}

	/// Values go back in the map's OWN coordinate system, unconverted — anything else would produce
	/// a link the app itself could not read.
	func testRefreshedExtent_IsNotConvertedToDegrees() {
		// A projected extent, matching the projected replacement. Pairing it with `1,2,3,4` would
		// now be refused as a units mismatch — the intended behaviour, not a gap.
		let stale = url("https://example.org/app?extent=-830000,-1030000,-825000,-1025000")
		let location = MapLocationResolver.resolve(url: stale, probe: probe(nativeExtent: [-820000, -1025000, -815000, -1020000]))
		XCTAssertTrue(location.sourceURL?.absoluteString.contains("-820000") ?? false)
	}

	func testURLWithNoViewportParameter_IsLeftAlone() {
		let plain = url("https://ags.cuzk.cz/av/")
		let location = MapLocationResolver.resolve(url: plain, probe: probe(nativeExtent: [1, 2, 3, 4]))
		XCTAssertEqual(location.sourceURL, plain, "a URL that carries no viewport must not be invented")
	}

	/// A parameter whose value is not a viewport must not be rewritten just because its name matches.
	func testNonNumericViewportParameter_IsNotTouched() {
		let odd = url("https://example.org/app?center=auto")
		let location = MapLocationResolver.resolve(url: odd, probe: probe(nativeCenter: [10, 20]))
		XCTAssertEqual(location.sourceURL, odd)
	}

	/// The live map always reports `x, y`, but `ll=` and `pos=` are written latitude-first. Writing
	/// one convention into the other transposes the pair into a valid-looking URL pointing somewhere
	/// else — so the order is chosen by whichever lands nearer what the parameter already held.
	func testCentreRefresh_KeepsTheOrderTheURLWasAlreadyUsing() {
		let latitudeFirst = url("https://example.org/app?ll=47.941230,18.709545")
		let location = MapLocationResolver.resolve(
			url: latitudeFirst,
			probe: probe(nativeCenter: [18.71, 47.95], nativeWkid: 4326)
		)
		let refreshed = location.sourceURL?.absoluteString ?? ""
		XCTAssertTrue(refreshed.contains("ll=47.95,18.71"), "expected latitude first, got \(refreshed)")
	}

	func testCentreRefresh_LongitudeFirstParameterStaysLongitudeFirst() {
		let longitudeFirst = url("https://example.org/app?center=18.709545,47.941230")
		let location = MapLocationResolver.resolve(
			url: longitudeFirst,
			probe: probe(nativeCenter: [18.71, 47.95], nativeWkid: 4326)
		)
		XCTAssertTrue(location.sourceURL?.absoluteString.contains("center=18.71,47.95") ?? false)
	}

	/// Order comes from the parameter's own convention, never from proximity to the stale value.
	func testOrdered_FollowsTheParameterName() {
		// `ll`/`pos`/`loc` are latitude-first; the map reports x, y.
		XCTAssertEqual(MapURLViewportRefresh.ordered([18.7, 47.9], for: "ll"), [47.9, 18.7])
		XCTAssertEqual(MapURLViewportRefresh.ordered([18.7, 47.9], for: "pos"), [47.9, 18.7])
		// `center`/`c` are longitude-first in the ecosystems that use them.
		XCTAssertEqual(MapURLViewportRefresh.ordered([18.7, 47.9], for: "center"), [18.7, 47.9])
		// A name with no known convention is refused rather than guessed.
		XCTAssertNil(MapURLViewportRefresh.ordered([18.7, 47.9], for: "q"))
	}

	/// The counterexample that retired the proximity heuristic: a large pan makes "whichever is
	/// nearer the old value" pick the transposed arrangement.
	func testOrdered_LargePan_IsNotTransposed() {
		// Stale `ll=10,80`; the map is now at x,y = -70,20. Proximity would choose -70,20 — the
		// wrong way round. The name says latitude first, so the answer is 20,-70.
		XCTAssertEqual(MapURLViewportRefresh.ordered([-70, 20], for: "ll"), [20, -70])
	}

	func testCentreRefresh_UnknownParameterName_IsRefused() {
		let unknown = url("https://example.org/app?q=10,80")
		let location = MapLocationResolver.resolve(url: unknown, probe: probe(nativeCenter: [-70, 20]))
		XCTAssertEqual(location.sourceURL, unknown, "an unknown ordering must not be guessed")
	}

	// MARK: - Fragment viewports

	/// Reported from the app: demotiles and basemap.at recorded a generic URL, so opening the
	/// finding's link showed a whole globe rather than the place. Both keep their viewport in the
	/// fragment, which the named-parameter refresh never looked at.
	func testMapLibreHash_IsRefreshedFromTheLiveMap() {
		let stale = url("https://example.org/#1.5/0/0")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertEqual(location.sourceURL?.fragment, "1.5/47.94123/18.709545")
	}

	func testOSMStyleHash_KeepsItsPrefixAndTrailingState() {
		// Decimals: an all-integer triple is deliberately refused, because three integers split by
		// slashes is also what a date route looks like.
		let stale = url("https://example.org/#map=15/10.0/10.0&layers=X")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		let fragment = location.sourceURL?.fragment ?? ""
		XCTAssertTrue(fragment.hasPrefix("map=15/47.94123/18.709545"), fragment)
		XCTAssertTrue(fragment.hasSuffix("&layers=X"), "the app's other state must survive: \(fragment)")
	}

	/// A JSON view state, as OpenLayers applications write. The centre goes back in the map's own
	/// units — converting it would produce a link the app could not read.
	func testJSONFragment_CentreIsRefreshedInTheMapsOwnUnits() {
		let stale = url("https://example.org/app#%7B%22center%22:%5B1445590,6059660%5D,%22zoom%22:8%7D")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(nativeCenter: [1446284.5383729, 6037564.370422], nativeWkid: 3857)
		)
		let fragment = (location.sourceURL?.fragment ?? "").removingPercentEncoding ?? ""
		XCTAssertTrue(fragment.contains("1446284.5383729"), fragment)
		XCTAssertTrue(fragment.contains("\"zoom\""), "unrelated view state must survive: \(fragment)")
	}

	/// A hash that is not a viewport must not be rewritten.
	func testUnrelatedFragment_IsLeftAlone() {
		let plain = url("https://example.org/page#section-3")
		let location = MapLocationResolver.resolve(url: plain, probe: probe(live: coordinate(48.8, 19.53)))
		XCTAssertEqual(location.sourceURL, plain)
	}

	/// A page that never rewrites its own hash is not using it as state.
	///
	/// demotiles.maplibre.org opens `#3.38/54.22/-177.33` at the default view and never updates the
	/// hash while panning. Writing a viewport into it produced a link that looked precise and went
	/// nowhere — the failure this whole file exists to prevent, arriving through the back door.
	func testFragmentRefresh_IsSkippedWhenThePageNeverMaintainsItsURL() {
		let stale = url("https://example.org/#1.5/0/0")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(live: coordinate(47.941230, 18.709545)),
			pageMaintainsItsURL: false
		)
		XCTAssertEqual(location.sourceURL, stale, "a hash the page ignores must not be rewritten")
	}

	/// A query viewport carries no such doubt: it is what a site's own share action produces.
	func testQueryRefresh_HappensEvenWhenThePageNeverMaintainsItsURL() {
		let stale = url("https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39")
		let location = MapLocationResolver.resolve(
			url: stale,
			probe: probe(nativeExtent: [-820000, -1025000, -815000, -1020000]),
			pageMaintainsItsURL: false
		)
		XCTAssertTrue(location.sourceURL?.absoluteString.contains("-820000") ?? false)
	}

	// MARK: - Units must not be silently swapped

	/// A degrees parameter must never receive metres. `?center=18.7,47.9` with a Web-Mercator view
	/// would otherwise become `center=1605000,6461000` — a confident, wrong link, with nothing on it
	/// to say the units changed.
	func testDegreeParameter_IsNotOverwrittenWithProjectedMetres() {
		let degrees = url("https://example.org/app?center=18.709545,47.941230")
		let location = MapLocationResolver.resolve(
			url: degrees,
			probe: probe(nativeCenter: [1_605_000.0, 6_461_000.0], nativeWkid: 3857)
		)
		XCTAssertEqual(location.sourceURL, degrees, "metres were written into a degrees parameter")
	}

	/// And the reverse: a projected parameter must not receive degrees.
	func testProjectedParameter_IsNotOverwrittenWithDegrees() {
		let projected = url("https://example.org/app?extent=-832098,-1032881,-825377,-1029661")
		let location = MapLocationResolver.resolve(
			url: projected,
			probe: probe(nativeExtent: [14.0, 50.0, 15.0, 51.0], nativeWkid: 4326)
		)
		XCTAssertEqual(location.sourceURL, projected)
	}

	func testJSONFragment_UnitMismatch_IsRefused() {
		let degrees = url("https://example.org/app#%7B%22center%22:%5B18.7,47.9%5D,%22zoom%22:8%7D")
		let location = MapLocationResolver.resolve(
			url: degrees,
			probe: probe(nativeCenter: [1_446_284.5, 6_037_564.4], nativeWkid: 3857)
		)
		XCTAssertEqual(location.sourceURL, degrees)
	}

	func testUnitsAgree_ComparesMagnitudeClass() {
		XCTAssertTrue(MapURLViewportRefresh.unitsAgree(existing: [18.7, 47.9], replacement: [19.0, 48.0]))
		XCTAssertFalse(MapURLViewportRefresh.unitsAgree(existing: [18.7, 47.9], replacement: [1_605_000, 6_461_000]))
		XCTAssertFalse(MapURLViewportRefresh.unitsAgree(existing: [-832_098, -1_032_881], replacement: [14.0, 50.0]))
	}

	// MARK: - A hash of three numbers is not always a viewport

	/// `#2024/05/01` is a date route. Before this guard it was rewritten into a viewport the moment
	/// any live reading existed.
	func testDateLikeFragment_IsNotMistakenForAViewport() {
		let route = url("https://example.org/archive#2024/05/01")
		let location = MapLocationResolver.resolve(url: route, probe: probe(live: coordinate(47.941230, 18.709545)))
		XCTAssertEqual(location.sourceURL, route)
	}

	func testFragmentWithImplausibleZoom_IsNotRewritten() {
		let odd = url("https://example.org/#45/10.5/10.5")
		let location = MapLocationResolver.resolve(url: odd, probe: probe(live: coordinate(47.941230, 18.709545)))
		XCTAssertEqual(location.sourceURL, odd)
	}

	func testFragmentWithOutOfRangeLatitude_IsNotRewritten() {
		let odd = url("https://example.org/#10/91.5/10.5")
		let location = MapLocationResolver.resolve(url: odd, probe: probe(live: coordinate(47.941230, 18.709545)))
		XCTAssertEqual(location.sourceURL, odd)
	}

	// MARK: - Prefill

	func testPrefill_CarriesProvenanceSoAReaderCanTellWhereItCameFrom() {
		let live = MapLocationResolver.resolve(
			url: url("https://example.org/"),
			probe: probe(live: coordinate(47.941230, 18.709545))
		)
		XCTAssertEqual(live.gpsPrefill, "leaflet: 47.94123, 18.709545")

		let fromURL = MapLocationResolver.resolve(url: url("https://example.org/#map=15/47.941230/18.709545"))
		XCTAssertEqual(fromURL.gpsPrefill, "url: 47.941230, 18.709545")
	}
}
