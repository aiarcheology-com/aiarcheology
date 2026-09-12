//
//  MapURLLocationInferenceTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: the recorded-URL corpus. Every expectation is an exact reference pair, because the
//  one failure range validation cannot catch is a transposed coordinate — and a test written with
//  the axes swapped in both places would pass while the app saved the wrong continent.
//

import XCTest
@testable import ML_Browser

final class MapURLLocationInferenceTests: XCTestCase {

	private func reading(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> MapLocationReading? {
		guard let url = URL(string: string) else {
			XCTFail("not a URL: \(string)", file: file, line: line)
			return nil
		}
		return MapURLLocationInference.reading(from: url)
	}

	private func assertCoordinate(
		_ string: String,
		latitude: Double,
		longitude: Double,
		source: MapLocationSource? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard let hit = reading(string, file: file, line: line) else {
			XCTFail("expected a reading from \(string)", file: file, line: line)
			return
		}
		XCTAssertEqual(hit.coordinate.latitude, latitude, accuracy: 0.0000001, "latitude", file: file, line: line)
		XCTAssertEqual(hit.coordinate.longitude, longitude, accuracy: 0.0000001, "longitude", file: file, line: line)
		XCTAssertEqual(hit.confidence, .inferred, "URL readings are never exact", file: file, line: line)
		if let source {
			XCTAssertEqual(hit.source, source, file: file, line: line)
		}
	}

	private func assertNoCoordinate(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertNil(reading(string, file: file, line: line), "expected no reading from \(string)", file: file, line: line)
	}

	// MARK: - Named pairs

	func testNamedPair_LatLon() {
		assertCoordinate("https://example.org/map?lat=53.15163&lon=-3.87707",
		                 latitude: 53.15163, longitude: -3.87707, source: .urlParameters)
	}

	func testNamedPair_LatitudeLongitudeSpelledOut() {
		assertCoordinate("https://example.org/?latitude=48.8&longitude=19.53", latitude: 48.8, longitude: 19.53)
	}

	func testNamedPair_LngSpelling() {
		assertCoordinate("https://example.org/?lat=48.8&lng=19.53", latitude: 48.8, longitude: 19.53)
	}

	func testNamedPair_OSMStyleMarker() {
		assertCoordinate("https://example.org/?mlat=52.5&mlon=13.4", latitude: 52.5, longitude: 13.4)
	}

	/// The National Library of Scotland grammar from the research table.
	func testNamedPair_InFragment() {
		assertCoordinate("https://maps.nls.uk/geo/explore/side-by-side/#zoom=6.3&lat=53.15163&lon=-3.87707&layers=1",
		                 latitude: 53.15163, longitude: -3.87707)
	}

	/// Mapy publishes `x` as longitude and `y` as latitude. The names carry the meaning, so this is
	/// read without any per-site knowledge — and without re-ordering the stored text.
	func testNamedPair_XYAreLongitudeAndLatitude() {
		assertCoordinate("https://en.mapy.cz/letecka?x=15.2751604&y=49.5874527&z=6",
		                 latitude: 49.5874527, longitude: 15.2751604)
	}

	func testNamedPair_ConflictingRepeats_AreRejected() {
		assertNoCoordinate("https://example.org/?lat=48.8&lat=49.9&lon=19.53")
	}

	func testNamedPair_AgreeingRepeats_AreAccepted() {
		assertCoordinate("https://example.org/?lat=48.8&lat=48.8&lon=19.53", latitude: 48.8, longitude: 19.53)
	}

	func testNamedPair_ZoomIsCapturedButNeverPartOfTheCoordinate() {
		let hit = reading("https://example.org/?lat=48.8&lon=19.53&zoom=14")
		XCTAssertEqual(hit?.zoom, 14)
		XCTAssertFalse(hit?.displayText.contains("14") ?? true, "zoom must not leak into the stored pair")
	}

	// MARK: - Named tuples

	/// CalTopo's grammar, and Google's `ll`.
	func testTuple_LL_IsLatitudeFirst() {
		assertCoordinate("https://caltopo.com/map.html#ll=38.97469,-100.06486&z=18&b=r",
		                 latitude: 38.97469, longitude: -100.06486)
	}

	/// ArcGIS Hub `explore` pages — 6 sites in the measured catalogue.
	func testTuple_Location_IsLatitudeFirstWithZoom() {
		let hit = reading("https://example.org/datasets/abc/explore?location=48.800000%2C19.530000%2C8")
		XCTAssertEqual(hit?.coordinate.latitude ?? 0, 48.8, accuracy: 0.0000001)
		XCTAssertEqual(hit?.coordinate.longitude ?? 0, 19.53, accuracy: 0.0000001)
		XCTAssertEqual(hit?.zoom, 8)
	}

	/// ZBGIS, from the research table.
	func testTuple_Pos_IsLatitudeFirstWithZoom() {
		assertCoordinate("https://zbgis.skgeodesy.sk/mkzbgis/en/teren?pos=48.800000,19.530000,8",
		                 latitude: 48.8, longitude: 19.53)
	}

	/// `center` is written longitude-first by OpenLayers and ArcGIS but latitude-first by Google,
	/// so it is only read when one of the two orders is impossible.
	func testTuple_Center_ResolvedWhenOnlyOneOrderIsValid() {
		assertCoordinate("https://example.org/?center=-100.06486,38.97469", latitude: 38.97469, longitude: -100.06486)
	}

	func testTuple_Center_RejectedWhenBothOrdersAreValid() {
		assertNoCoordinate("https://example.org/?center=48.8,19.53")
	}

	func testTuple_Extent_UsesTheRectangleCentre() {
		assertCoordinate("https://example.org/?extent=14.0,50.0,15.0,51.0&crs=CRS:84",
		                 latitude: 50.5, longitude: 14.5)
	}

	func testTuple_Extent_RejectedWhenTheRectangleIsInverted() {
		assertNoCoordinate("https://example.org/?extent=15.0,51.0,14.0,50.0&crs=CRS:84")
	}

	/// CUZK's extent is S-JTSK metres. Range validation alone rejects it — no hostname needed.
	func testTuple_Extent_ProjectedValues_AreRejected() {
		assertNoCoordinate("https://ags.cuzk.gov.cz/av/?extent=-750000,-1050000,-730000,-1030000")
	}

	// MARK: - bbox needs an explicit geographic declaration

	func testBBox_WithWGS84Marker_IsRead() {
		assertCoordinate("https://example.org/wms?bbox=14.0,50.0,15.0,51.0&crs=EPSG:4326",
		                 latitude: 50.5, longitude: 14.5)
	}

	/// The common case: a WMS bbox in the layer's own projection, with no marker at all. Those
	/// numbers are usually metres, so without a declaration they are not degrees.
	func testBBox_WithoutMarker_IsIgnored() {
		assertNoCoordinate("https://example.org/wms?bbox=14.0,50.0,15.0,51.0")
	}

	func testBBox_WithForeignCRS_IsIgnored() {
		assertNoCoordinate("https://example.org/wms?bbox=14.0,50.0,15.0,51.0&crs=EPSG:25832")
	}

	// MARK: - Fragment paths

	/// Freemap, from the research table.
	func testFragmentPath_OSMMapGrammar() {
		assertCoordinate("https://www.freemap.sk/#map=15/47.941230/18.709545",
		                 latitude: 47.941230, longitude: 18.709545, source: .urlHashPath)
	}

	/// Boydsmaps: layer and display fields follow the viewport, and must not confuse the triple.
	func testFragmentPath_TrailingLayerFieldsAreIgnored() {
		assertCoordinate("https://boydsmaps.com/#14.00/39.739879/-74.223193/us3depShade1/0.00/0.00",
		                 latitude: 39.739879, longitude: -74.223193)
	}

	/// The MapLibre/Leaflet standard hash, with coordinates carrying few decimals. An earlier
	/// "zoom has the fewest fraction digits" rule rejected this; the positional convention does not.
	func testFragmentPath_RoundedCoordinates() {
		assertCoordinate("https://example.org/#12.5/51.5/-0.12", latitude: 51.5, longitude: -0.12)
	}

	/// basemap.at's real zoom carries more decimals than its own coordinates — the case that
	/// disproved the digit-counting heuristic.
	func testFragmentPath_ZoomWithManyDecimals() {
		assertCoordinate("https://example.org/#8.315811036165348/48.208000/16.373800",
		                 latitude: 48.208, longitude: 16.3738)
	}

	func testFragmentPath_AllIntegerTriple_IsRejectedAsImplausible() {
		assertNoCoordinate("https://example.org/#13/47/18")
	}

	func testFragmentPath_ZoomOutOfRange_IsRejected() {
		assertNoCoordinate("https://example.org/#45/47.9412/18.7095")
	}

	func testFragmentPath_WebMercatorValues_AreRejected() {
		assertNoCoordinate("https://example.org/#10/1445590.0/6059660.0")
	}

	func testFragmentPath_LatitudeOutOfRange_IsRejected() {
		assertNoCoordinate("https://example.org/#10/91.5/10.5")
	}

	/// Single-page apps route in the fragment, so the parameters sit behind a router path.
	func testHashRouter_ParametersAfterAPathAreFound() {
		assertCoordinate("https://example.org/#/map?lat=48.8&lon=19.53", latitude: 48.8, longitude: 19.53)
		assertCoordinate("https://example.org/#/viewer/2d?zoom=12&lat=53.15163&lon=-3.87707",
		                 latitude: 53.15163, longitude: -3.87707)
	}

	// MARK: - `@lat,lon,Nz` in the path

	func testAtPath_GoogleStyle() {
		assertCoordinate("https://example.org/maps/@50.0755381,14.4378005,15z",
		                 latitude: 50.0755381, longitude: 14.4378005)
	}

	func testAtPath_ZoomSuffixIsRead() {
		XCTAssertEqual(reading("https://example.org/maps/@50.0755381,14.4378005,15z")?.zoom, 15)
	}

	// MARK: - Foreign coordinate reference systems

	/// Wind-Atlas serialises its centre in EPSG:25832 and says so. The marker is what stops those
	/// metres being read as degrees.
	func testForeignCRSMarker_AbandonsTheWholeURL() {
		assertNoCoordinate("https://example.org/app/index.html?lang=en&vm=2D&s=50000&c=500000,5500000&srs=25832")
	}

	/// The counterexample that killed the "projected values are always out of range" argument: an
	/// EPSG:3857 view near the origin is inside ±180 and would otherwise be saved as 50°N 100°E.
	func testForeignCRSMarker_ProtectsInRangeProjectedValues() {
		assertNoCoordinate("https://example.org/?x=100&y=50&srs=EPSG:3857")
	}

	/// The guard has to see a marker that sits behind a router path. Reading the raw fragment parsed
	/// `#/map?srs=EPSG:3857&x=100&y=50` as one field named `/map?srs`, so the marker was invisible
	/// and 100/50 metres were stored as degrees.
	func testForeignCRSMarker_BehindAHashRoute_IsStillSeen() {
		assertNoCoordinate("https://example.org/#/map?srs=EPSG:3857&x=100&y=50")
		assertNoCoordinate("https://example.org/#/viewer?crs=EPSG:25832&lat=48.8&lon=19.53")
	}

	/// An extent with no geographic declaration can be metres near a projection's origin, and its
	/// midpoint then looks like a perfectly ordinary coordinate.
	func testExtent_WithoutAWGS84Marker_IsIgnored() {
		assertNoCoordinate("https://example.org/?extent=0,0,100,50")
	}

	func testExtent_WithWGS84Marker_IsRead() {
		assertCoordinate("https://example.org/?extent=14.0,50.0,15.0,51.0&crs=EPSG:4326",
		                 latitude: 50.5, longitude: 14.5)
	}

	func testWGS84Marker_DoesNotBlockReading() {
		assertCoordinate("https://example.org/?lat=48.8&lon=19.53&crs=EPSG:4326", latitude: 48.8, longitude: 19.53)
	}

	// MARK: - Content identifiers must never look like places

	func testArcGISWebMapIdentifier_YieldsNothing() {
		assertNoCoordinate("https://www.arcgis.com/apps/mapviewer/index.html?webmap=4931f75a164a474d91d9a3dccecee08b")
	}

	func testArcGISWebAppIdentifier_YieldsNothing() {
		assertNoCoordinate("https://example.maps.arcgis.com/apps/webappviewer/index.html?id=5e3071044cb44e76843d110baef8b138")
	}

	func testExperienceBuilderRoute_YieldsNothing() {
		assertNoCoordinate("https://experience.arcgis.com/experience/8bed1358b2534a0f8e66fd2d3196b2d5/page/2022-Apr/")
	}

	func testPlainPage_YieldsNothing() {
		assertNoCoordinate("https://ags.cuzk.gov.cz/av/")
		assertNoCoordinate("https://www.lidarandaerialarchaeology.com/europe/")
	}

	// MARK: - Malformed numbers

	func testMalformedNumbers_AreRejected() {
		assertNoCoordinate("https://example.org/?lat=&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=abc&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=1e5&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=inf&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=nan&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=91&lon=19.53")
		assertNoCoordinate("https://example.org/?lat=48.8&lon=181")
	}

	// MARK: - Stored text is verbatim

	/// The user's rule: do not translate what the URL said. The stored pair keeps the URL's own
	/// spelling, including trailing zeros that a round-trip through `Double` would drop.
	func testStoredText_PreservesTheURLsOwnSpelling() {
		XCTAssertEqual(
			reading("https://www.freemap.sk/#map=15/47.941230/18.709545")?.displayText,
			"url: 47.941230, 18.709545"
		)
	}

	/// A transposition is invisible to every range check, so the corpus pins real values. If the
	/// implementation ever swaps the axes, this is the test that fails.
	func testAxisOrder_IsPinnedAgainstTransposition() {
		let hit = reading("https://www.freemap.sk/#map=15/47.941230/18.709545")
		XCTAssertEqual(hit?.coordinate.latitude ?? 0, 47.941230, accuracy: 0.0000001)
		XCTAssertEqual(hit?.coordinate.longitude ?? 0, 18.709545, accuracy: 0.0000001)
		XCTAssertNotEqual(hit?.coordinate.latitude ?? 0, 18.709545, accuracy: 0.0000001)
	}
}
