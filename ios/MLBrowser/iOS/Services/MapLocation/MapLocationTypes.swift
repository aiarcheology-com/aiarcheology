//
//  MapLocationTypes.swift
//  AI Archeology
//
//  What a map page told us about where it is looking (AIA-0817).
//

import Foundation

// swiftlint:disable redundant_string_enum_value - see the note on raw values below.
/// Which mechanism produced a reading.
///
/// This is a *capability* key, never a site key: the whole point of AIA-0817 is that coverage grows
/// by adding a library adapter or a standard grammar, not by adding a hostname. Nothing in the
/// shipped decision path branches on a domain.
///
/// The raw values repeat the case names deliberately, against SwiftLint's usual advice. Swift would
/// synthesise the same strings today — but it synthesises them *from the case names*, so a later
/// rename would silently rewrite a value that is already persisted in `Finding.gps_` and present in
/// exported archives. Spelling them out makes the rename harmless and the data contract visible.
enum MapLocationSource: String, Sendable, Equatable, CaseIterable {
	case leaflet = "leaflet"
	case openLayers = "openLayers"
	case openLayers2 = "openLayers2"
	case mapLibre = "mapLibre"
	case arcGIS = "arcGIS"
	case googleMaps = "googleMaps"
	case cesium = "cesium"
	/// A live map object found by duck typing, from a library this app has no named adapter for.
	/// Worth keeping and worth labelling honestly: the reading is as real as any other live-map
	/// reading, but claiming it came from a specific library would be a false statement in stored
	/// data.
	case liveMap = "liveMap"
	/// A named `lat`/`lon`-style pair in the URL's query or fragment.
	case urlParameters = "urlParameters"
	/// A positional grammar in the URL's fragment or path (`#map=z/lat/lon`, `@lat,lon,Nz`).
	case urlHashPath = "urlHashPath"
	/// `<link rel="canonical">`, `og:latitude`/`og:longitude`, or `geo.position`.
	case pageMetadata = "pageMetadata"
	/// A coordinate string the page was showing the user, copied verbatim.
	///
	/// Whatever format and datum the site chose travels with it, which is why it is stored as the
	/// site wrote it rather than reformatted.
	case displayedText = "displayedText"
	// swiftlint:enable redundant_string_enum_value

	/// Whether the value came from the live map object or was inferred from text.
	///
	/// Only a running map instance reporting its own centre counts as `exact`. Everything read out
	/// of a URL or a `<meta>` tag is `inferred`, because the text may describe a different view
	/// than the one on screen, or may not be a viewport at all.
	var confidence: MapLocationConfidence {
		switch self {
		case .leaflet, .openLayers, .openLayers2, .mapLibre, .arcGIS, .googleMaps, .cesium, .liveMap:
			return .exact
		case .urlParameters, .urlHashPath, .pageMetadata, .displayedText:
			return .inferred
		}
	}

	/// The token written in front of the coordinate in `Finding.gps_`.
	///
	/// Deliberately coarser than the case list — a reader wants to know "the map told us" versus
	/// "we read the URL", not which OpenLayers major version was involved. These strings are
	/// **stored data**: they are persisted, CSV/JSON-exported and shared, so they are fixed ASCII
	/// tokens and never localized prose, which would otherwise vary by device language and break
	/// round-tripping between users.
	var storageTag: String {
		switch self {
		case .leaflet: return "leaflet"
		case .openLayers, .openLayers2: return "openlayers"
		case .mapLibre: return "maplibre"
		case .arcGIS: return "arcgis"
		case .googleMaps: return "googlemaps"
		case .cesium: return "cesium"
		case .liveMap: return "map"
		case .urlParameters, .urlHashPath: return "url"
		case .pageMetadata: return "meta"
		case .displayedText: return "shown"
		}
	}

	/// Every tag this app may write into `gps_`.
	///
	/// `CoordinateText.parse` consults this to know which leading `tag:` prefixes it may strip. It
	/// is an allowlist rather than "any lowercase word" on purpose: a user's own note such as
	/// `note: 48.8, 19.53` must stay prose and must not silently become a map pin.
	static let storageTags: Set<String> = Set(allCases.map(\.storageTag))
}

/// How much a reading can be trusted. See ``MapLocationSource/confidence``.
enum MapLocationConfidence: String, Sendable, Equatable {
	case exact
	case inferred
}

/// A validated WGS-84 point.
///
/// Deliberately the *same* type the share link already uses rather than a parallel one: "is this a
/// real latitude/longitude" is one rule, and it already lives in `FindingShareLink.Coordinate`'s
/// failable initializer (finite, ±90/±180, no clamping). Duplicating it here would create a second
/// place for that rule to drift.
typealias MapCoordinate = FindingShareLink.Coordinate

/// One resolved position, and where it came from.
struct MapLocationReading: Sendable, Equatable {
	let coordinate: MapCoordinate
	/// The map's zoom when the source reported one. Recorded for provenance only — a zoom is not a
	/// coordinate and is never written into the GPS field.
	let zoom: Double?
	let source: MapLocationSource
	/// The coordinate exactly as the URL spelled it, when the source was text.
	///
	/// Preserved so a URL-derived value is stored verbatim — no re-ordering, no re-rounding. `nil`
	/// for live-map readings, which arrive as numbers and have no original spelling.
	let rawText: String?

	var confidence: MapLocationConfidence { source.confidence }

	init(coordinate: MapCoordinate, zoom: Double? = nil, source: MapLocationSource, rawText: String? = nil) {
		self.coordinate = coordinate
		self.zoom = zoom
		self.source = source
		self.rawText = rawText
	}

	/// What gets written into the finding's GPS field: `"<tag>: <coordinate>"`.
	///
	/// The tag comes first because the share card renders this string on one line with tail
	/// truncation (`FindingShareCard`), so a trailing marker is the part that disappears. A
	/// truncated `"lv95: 2692220.33, 11569…"` still reads as "not lat/lon"; a truncated
	/// `"2692220.33, 1156974.06 (LV95)"` reads as a location under a map-pin glyph.
	var displayText: String {
		"\(source.storageTag): \(rawText ?? Self.formattedPair(coordinate))"
	}

	/// Latitude then longitude, locale-independent.
	///
	/// `String(format:)` with no locale argument is explicitly non-localized, which matters because
	/// this string is stored and exported: a device set to a comma-decimal locale must not write
	/// `"48,8"` into a comma-separated pair.
	static func formattedPair(_ coordinate: MapCoordinate) -> String {
		"\(formatted(coordinate.latitude)), \(formatted(coordinate.longitude))"
	}

	/// Up to 7 fraction digits (~1 cm at the equator — beyond any map's real precision), with
	/// trailing zeros trimmed so a whole degree reads `48` rather than `48.0000000`.
	static func formatted(_ value: Double) -> String {
		var text = String(format: "%.7f", value)
		if text.contains(".") {
			while text.hasSuffix("0") { text.removeLast() }
			if text.hasSuffix(".") { text.removeLast() }
		}
		return text.isEmpty ? "0" : text
	}
}

/// Everything the resolver could establish about the page a finding was captured on.
struct MapPageLocation: Sendable, Equatable {
	/// The URL of the document the user was actually looking at.
	///
	/// Optional because a capture may genuinely have no URL — `FindingCapture.pageURL` is already
	/// optional and a blank web view is a real state. This is the ticket's floor: when every tier
	/// below fails, this is still what the finding records.
	let sourceURL: URL?
	/// A `<link rel="canonical">` or `og:url` that differs from `sourceURL`.
	///
	/// Never used to *replace* a source URL that carries viewport state in its query or fragment:
	/// a canonical link usually points at the app's landing page, which would throw away the exact
	/// view the user had found.
	let canonicalURL: URL?
	let reading: MapLocationReading?
	/// The map's own position when it is not in degrees, recorded verbatim with the name of its
	/// coordinate system — `S-JTSK (EPSG:5514): -828738.04, -1031271.56`.
	///
	/// A national-grid map knows exactly where it is looking; refusing anything but WGS-84 would
	/// record nothing at all, which is strictly worse. Nothing here is converted, so nothing here
	/// can be converted wrongly.
	let projectedText: String?
	/// Whether two independent tiers produced coordinates that agree.
	///
	/// Provenance only. A lone `exact` reading from a live map is not "worse" than a corroborated
	/// pair — this records that the URL and the map told the same story, which is the strongest
	/// evidence available without a device check.
	let corroborated: Bool

	init(
		sourceURL: URL?,
		canonicalURL: URL? = nil,
		reading: MapLocationReading? = nil,
		projectedText: String? = nil,
		corroborated: Bool = false
	) {
		self.sourceURL = sourceURL
		self.canonicalURL = canonicalURL
		self.reading = reading
		self.projectedText = projectedText
		self.corroborated = corroborated
	}

	/// The text to prefill the finding's GPS field with, or `nil` to leave it empty.
	/// Degrees when we have them; otherwise the map's own coordinate, named. Empty only when the
	/// page told us nothing at all.
	var gpsPrefill: String? { reading?.displayText ?? projectedText }
}
