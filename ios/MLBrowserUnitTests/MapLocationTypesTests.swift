//
//  MapLocationTypesTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: the stored shape of a resolved map location, and the tag rule that keeps an
//  auto-filled coordinate readable by the share link without turning prose into a map pin.
//

import XCTest
@testable import ML_Browser

final class MapLocationTypesTests: XCTestCase {

	private func coordinate(_ latitude: Double, _ longitude: Double) -> MapCoordinate {
		guard let value = MapCoordinate(latitude: latitude, longitude: longitude) else {
			preconditionFailure("test fixture is not a valid coordinate")
		}
		return value
	}

	// MARK: - Confidence

	func testConfidence_LiveMapSources_AreExact() {
		for source in [MapLocationSource.leaflet, .openLayers, .openLayers2, .mapLibre, .arcGIS, .googleMaps, .cesium, .liveMap] {
			XCTAssertEqual(source.confidence, .exact, "\(source.rawValue) reads a running map")
		}
	}

	func testConfidence_TextDerivedSources_AreInferred() {
		for source in [MapLocationSource.urlParameters, .urlHashPath, .pageMetadata, .displayedText] {
			XCTAssertEqual(source.confidence, .inferred, "\(source.rawValue) reads text, not a map")
		}
	}

	/// Every case must be classified. A new source added without a confidence would otherwise
	/// inherit whatever the switch's last branch happened to be.
	func testConfidence_EveryCaseIsClassified() {
		XCTAssertEqual(MapLocationSource.allCases.count, 12)
	}

	// MARK: - Raw values are stable data, not symbol names

	/// These strings are persisted in `Finding.gps_` and exported. If someone "tidies" a case name,
	/// the raw value must not move with it — old findings would stop round-tripping.
	func testRawValues_ArePinned() {
		XCTAssertEqual(MapLocationSource.leaflet.rawValue, "leaflet")
		XCTAssertEqual(MapLocationSource.openLayers2.rawValue, "openLayers2")
		XCTAssertEqual(MapLocationSource.urlHashPath.rawValue, "urlHashPath")
		XCTAssertEqual(MapLocationSource.pageMetadata.rawValue, "pageMetadata")
	}

	func testStorageTags_CollapseVariantsOfOneMechanism() {
		XCTAssertEqual(MapLocationSource.openLayers.storageTag, "openlayers")
		XCTAssertEqual(MapLocationSource.openLayers2.storageTag, "openlayers")
		XCTAssertEqual(MapLocationSource.liveMap.storageTag, "map")
		XCTAssertEqual(MapLocationSource.urlParameters.storageTag, "url")
		XCTAssertEqual(MapLocationSource.urlHashPath.storageTag, "url")
		XCTAssertEqual(MapLocationSource.pageMetadata.storageTag, "meta")
		XCTAssertEqual(MapLocationSource.displayedText.storageTag, "shown")
	}

	func testStorageTags_AreLowercaseAlphanumeric() {
		for tag in MapLocationSource.storageTags {
			XCTAssertEqual(tag, tag.lowercased())
			XCTAssertTrue(tag.allSatisfy { $0.isLetter || $0.isNumber }, "\(tag) must survive tag stripping")
		}
	}

	// MARK: - Number formatting

	func testFormatted_TrimsTrailingZerosButKeepsPrecision() {
		XCTAssertEqual(MapLocationReading.formatted(47.941230), "47.94123")
		XCTAssertEqual(MapLocationReading.formatted(48), "48")
		XCTAssertEqual(MapLocationReading.formatted(-74.223193), "-74.223193")
		XCTAssertEqual(MapLocationReading.formatted(0), "0")
	}

	/// The stored string must not follow the device language: a comma decimal separator would turn
	/// one coordinate into what reads as two.
	func testFormatted_IsLocaleIndependent() {
		XCTAssertFalse(MapLocationReading.formatted(48.8).contains(","))
		XCTAssertTrue(MapLocationReading.formatted(48.8).contains("."))
	}

	// MARK: - Display text

	func testDisplayText_LiveReading_TagsThenCoordinate() {
		let reading = MapLocationReading(coordinate: coordinate(47.941230, 18.709545), source: .leaflet)
		XCTAssertEqual(reading.displayText, "leaflet: 47.94123, 18.709545")
	}

	/// A URL-derived value keeps the URL's own spelling — no re-rounding, no re-ordering.
	func testDisplayText_URLReading_PreservesRawSpellingVerbatim() {
		let reading = MapLocationReading(
			coordinate: coordinate(47.941230, 18.709545),
			source: .urlHashPath,
			rawText: "47.941230, 18.709545"
		)
		XCTAssertEqual(reading.displayText, "url: 47.941230, 18.709545")
	}

	/// The tag leads because the share card truncates at the tail; a trailing marker is exactly the
	/// part that would be lost.
	func testDisplayText_TagIsAPrefixNotASuffix() {
		let reading = MapLocationReading(coordinate: coordinate(50.0755381, 14.4378005), source: .arcGIS)
		XCTAssertTrue(reading.displayText.hasPrefix("arcgis: "))
	}

	// MARK: - Round trip through the share-link parser

	func testTaggedDisplayText_StillParsesBackToTheSameCoordinate() {
		for source in MapLocationSource.allCases {
			let original = coordinate(47.941230, 18.709545)
			let reading = MapLocationReading(coordinate: original, source: source)
			let parsed = CoordinateText.parse(reading.displayText)
			XCTAssertEqual(parsed, original, "\(source.storageTag) tag broke the round trip")
		}
	}

	// MARK: - The allowlist is the point

	/// The failure this guards: treating any leading word as a tag. A note is prose, and inventing
	/// a pin from it would put a finding somewhere the user never confirmed.
	func testParse_UnknownTag_IsStillRejected() {
		XCTAssertNil(CoordinateText.parse("note: 48.8, 19.53"))
		XCTAssertNil(CoordinateText.parse("somewhere: 48.8, 19.53"))
		XCTAssertNil(CoordinateText.parse("gps: 48.8, 19.53"))
	}

	func testParse_TagIsCaseInsensitive() {
		XCTAssertEqual(CoordinateText.parse("Leaflet: 48.8, 19.53"), coordinate(48.8, 19.53))
		XCTAssertEqual(CoordinateText.parse("URL: 48.8, 19.53"), coordinate(48.8, 19.53))
	}

	/// Only one tag is stripped, so a doubled prefix stays malformed rather than being unwrapped
	/// until something parses.
	func testParse_OnlyOneTagIsStripped() {
		XCTAssertNil(CoordinateText.parse("url: url: 48.8, 19.53"))
	}

	func testParse_TagWithNoCoordinate_IsRejected() {
		XCTAssertNil(CoordinateText.parse("leaflet:"))
		XCTAssertNil(CoordinateText.parse("leaflet: not a place"))
	}

	// MARK: - Pre-existing behaviour must be untouched

	func testParse_UntaggedForms_BehaveExactlyAsBefore() {
		XCTAssertEqual(CoordinateText.parse("48.8, 19.53"), coordinate(48.8, 19.53))
		XCTAssertEqual(CoordinateText.parse("48.8 19.53"), coordinate(48.8, 19.53))
		XCTAssertEqual(CoordinateText.parse("48.8N, 19.53E"), coordinate(48.8, 19.53))
		XCTAssertEqual(CoordinateText.parse("N48.8 E19.53"), coordinate(48.8, 19.53))
		XCTAssertEqual(CoordinateText.parse("48.8S, 19.53W"), coordinate(-48.8, -19.53))
		XCTAssertNil(CoordinateText.parse(""))
		XCTAssertNil(CoordinateText.parse("somewhere nice"))
		XCTAssertNil(CoordinateText.parse("-48.8N, 19.53E"))
		XCTAssertNil(CoordinateText.parse("48.8"))
	}

	/// A colon that is not a tag separator must not corrupt an otherwise ordinary rejection.
	func testParse_ColonInProse_DoesNotBecomeATag() {
		XCTAssertNil(CoordinateText.parse("see: notes"))
		XCTAssertNil(CoordinateText.parse(": 48.8, 19.53"))
	}

	// MARK: - Page location

	func testPageLocation_WithNoReading_StillCarriesTheURL() {
		let url = URL(string: "https://ags.cuzk.gov.cz/av/")
		let location = MapPageLocation(sourceURL: url)
		XCTAssertEqual(location.sourceURL, url)
		XCTAssertNil(location.gpsPrefill)
		XCTAssertFalse(location.corroborated)
	}

	func testPageLocation_GPSPrefill_IsTheReadingsDisplayText() {
		let location = MapPageLocation(
			sourceURL: URL(string: "https://example.org/"),
			reading: MapLocationReading(coordinate: coordinate(48.8, 19.53), source: .mapLibre)
		)
		XCTAssertEqual(location.gpsPrefill, "maplibre: 48.8, 19.53")
	}
}
