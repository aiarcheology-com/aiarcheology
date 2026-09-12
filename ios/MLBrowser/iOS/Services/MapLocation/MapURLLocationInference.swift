//
//  MapURLLocationInference.swift
//  AI Archeology
//
//  Reading a viewport out of a map app's URL, without knowing which app it is (AIA-0817).
//

import Foundation

/// Extracts a WGS-84 coordinate from a URL using only *standard* grammars and parameter names.
///
/// ## Why there are no hostnames here
/// The app targets ~200 mapping sites, so any design whose coverage grows by hand-written domains
/// is the wrong one. Everything below keys on a parameter name or a positional grammar that many
/// unrelated sites share — `lat`/`lon`, OpenStreetMap's `#map=Z/LAT/LON`, Google's `@LAT,LON,Nz`.
/// Adding a name to a vocabulary set widens coverage across every site that uses it.
///
/// ## What this can get wrong
/// It can produce a **transposed** coordinate, and no amount of validation closes that. A site
/// serialising its fragment as `zoom/lon/lat` with a longitude inside ±90 yields a pair that passes
/// every finiteness and range check while pointing somewhere else entirely — `47.94/18.71` reversed
/// is a valid point about 3000 km away. Grammars with a documented order are trusted; grammars
/// without one are accepted only when exactly one reading is valid.
///
/// That residual risk was accepted deliberately in favour of coverage. It is bounded by three
/// things: every result here is `.inferred`, never `.exact`; the stored value carries a visible
/// `url:` tag so a reader can see where it came from; and the field stays editable. A live-map
/// reading, when one is available, always wins.
enum MapURLLocationInference {

	/// Parameter names that mean "latitude" across many unrelated mapping sites.
	private static let latitudeNames: Set<String> = ["lat", "latitude", "mlat", "y"]
	/// Parameter names that mean "longitude". `x`/`y` are included for coverage; see
	/// ``carriesForeignCRSMarker(_:)`` for the guard that keeps projected `x`/`y` out.
	private static let longitudeNames: Set<String> = ["lon", "lng", "long", "longitude", "mlon", "x"]

	/// Zoom levels live here. Web maps stop around 22-24; anything else is not a zoom.
	private static let zoomRange: ClosedRange<Double> = 0...24

	/// The result of resolving a URL, or `nil` when nothing could be read safely.
	static func reading(from url: URL) -> MapLocationReading? {
		// A URL that names a projection other than WGS-84 is describing its numbers in metres or
		// grid units. Reading those as degrees is the one failure that silently saves a real place
		// that the user never visited, so the whole URL is abandoned rather than partially trusted.
		guard carriesForeignCRSMarker(url).not else { return nil }

		let query = keyValues(url.query)
		// Single-page apps route in the fragment — `#/map?lat=48.8&lon=19.5` — so the query part of
		// the fragment has to be split off before it can be read as parameters at all.
		let fragment = queryPortion(of: url.fragment.map(percentDecoded) ?? "")
		let fragmentPairs = keyValues(fragment)
		let all = query + fragmentPairs

		// Ordered by how much the grammar itself tells us. A named pair states which value is
		// which; a positional triple only states an order by convention.
		if let hit = namedPair(in: all) { return hit }
		if let hit = namedTriple(in: all, url: url) { return hit }
		if let hit = fragmentPath(fragment) { return hit }
		if let hit = atPath(url) { return hit }
		return nil
	}

	// MARK: - Named pairs: `?lat=48.8&lon=19.53`

	/// A pair whose *names* say which value is which. The strongest URL evidence available, because
	/// no ordering convention has to be assumed.
	private static func namedPair(in pairs: [(name: String, value: String)]) -> MapLocationReading? {
		guard let latitude = uniqueValue(named: latitudeNames, in: pairs),
		      let longitude = uniqueValue(named: longitudeNames, in: pairs),
		      let coordinate = MapCoordinate(latitude: latitude.number, longitude: longitude.number)
		else { return nil }
		return MapLocationReading(
			coordinate: coordinate,
			zoom: zoomValue(in: pairs),
			source: .urlParameters,
			rawText: "\(latitude.text), \(longitude.text)"
		)
	}

	/// Exactly one usable value for a concept.
	///
	/// Repeated parameters that disagree (`?lat=48.8&lat=49.9`) mean the URL is ambiguous about its
	/// own viewport; guessing which one the app honoured would be inventing a location. Repeats
	/// that agree are harmless and accepted.
	private static func uniqueValue(
		named names: Set<String>,
		in pairs: [(name: String, value: String)]
	) -> (number: Double, text: String)? {
		let matches = pairs
			.filter { names.contains($0.name.lowercased()) }
			.compactMap { pair in strictDouble(pair.value).map { (number: $0, text: pair.value) } }
		guard let first = matches.first else { return nil }
		guard matches.allSatisfy({ $0.number == first.number }) else { return nil }
		return first
	}

	private static func zoomValue(in pairs: [(name: String, value: String)]) -> Double? {
		guard let raw = pairs.first(where: { ["z", "zoom"].contains($0.name.lowercased()) })?.value,
		      let value = strictDouble(raw), zoomRange.contains(value)
		else { return nil }
		return value
	}

	// MARK: - Named tuples: `?ll=48.8,19.53`, `?pos=48.8,19.53,8`, `?bbox=...`

	/// How a named tuple lays out its members. Each grammar states its own order, so no positional
	/// guessing is needed for these — that guessing is confined to ``fragmentPath(_:)``.
	private enum TupleLayout {
		/// Latitude first: the documented order for `ll`, `location` and `pos`.
		case latitudeFirst
		/// Order genuinely varies between ecosystems (OpenLayers and ArcGIS write longitude first,
		/// Google writes latitude first), so it is resolved by uniqueness rather than assumed.
		case ambiguous
		/// `minx,miny,maxx,maxy` — a rectangle whose centre is the viewport.
		case boundingBox
	}

	private static let tupleNames: [(name: String, layout: TupleLayout, requiresWGS84Marker: Bool)] = [
		("ll", .latitudeFirst, false),
		("location", .latitudeFirst, false),
		("pos", .latitudeFirst, false),
		("center", .ambiguous, false),
		("centre", .ambiguous, false),
		// Requires a geographic declaration for the same reason `bbox` does. `?extent=0,0,100,50`
		// passes every ordering and range check and becomes 25N 50E, even when those are metres near
		// a projection's origin. A real geographic extent says so.
		("extent", .boundingBox, true),
		// A `bbox` is usually an OGC WMS request in the layer's own projection, and those numbers
		// are metres far more often than degrees. It is read only when the URL says outright that
		// it is geographic; otherwise the CRS is unknown and the values are not degrees.
		("bbox", .boundingBox, true)
	]

	private static func namedTriple(in pairs: [(name: String, value: String)], url: URL) -> MapLocationReading? {
		for spec in tupleNames {
			// Every occurrence, not the first. Share links do repeat a parameter, and when the copies
			// disagree there is no principled way to pick one — taking `first` recorded an arbitrary
			// viewport as if it were the page's (raised in review). This mirrors what `uniqueValue`
			// already does for `lat`/`lon`.
			let occurrences = pairs.filter { $0.name.lowercased() == spec.name }.map(\.value)
			guard let raw = occurrences.first, occurrences.allSatisfy({ $0 == raw }) else { continue }
			if spec.requiresWGS84Marker && declaresWGS84(url).not { continue }
			let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
			guard let hit = coordinate(fromTuple: parts, layout: spec.layout) else { continue }
			return MapLocationReading(
				coordinate: hit.coordinate,
				zoom: hit.zoom ?? zoomValue(in: pairs),
				source: .urlParameters,
				rawText: hit.rawText
			)
		}
		return nil
	}

	private static func coordinate(
		fromTuple parts: [String],
		layout: TupleLayout
	) -> (coordinate: MapCoordinate, zoom: Double?, rawText: String)? {
		let numbers = parts.compactMap(strictDouble)
		guard numbers.count == parts.count else { return nil }

		switch layout {
		case .boundingBox:
			// minx,miny,maxx,maxy in degrees. The ordering check is what rejects a projected extent
			// that happens to fall inside the geographic range.
			guard numbers.count == 4 else { return nil }
			let (minX, minY, maxX, maxY) = (numbers[0], numbers[1], numbers[2], numbers[3])
			guard minX <= maxX, minY <= maxY,
			      let coordinate = MapCoordinate(latitude: (minY + maxY) / 2, longitude: (minX + maxX) / 2)
			else { return nil }
			return (coordinate, nil, MapLocationReading.formattedPair(coordinate))

		case .latitudeFirst:
			guard numbers.count >= 2,
			      let coordinate = MapCoordinate(latitude: numbers[0], longitude: numbers[1])
			else { return nil }
			let zoom = numbers.count > 2 && zoomRange.contains(numbers[2]) ? numbers[2] : nil
			return (coordinate, zoom, "\(parts[0]), \(parts[1])")

		case .ambiguous:
			guard numbers.count >= 2 else { return nil }
			let latitudeFirst = MapCoordinate(latitude: numbers[0], longitude: numbers[1])
			let longitudeFirst = MapCoordinate(latitude: numbers[1], longitude: numbers[0])
			// Both readings valid means the URL genuinely does not say which is which; there is no
			// safe answer, and a coin flip would put half of them in the wrong hemisphere.
			switch (latitudeFirst, longitudeFirst) {
			case let (value?, nil):
				return (value, nil, "\(parts[0]), \(parts[1])")
			case let (nil, value?):
				return (value, nil, "\(parts[1]), \(parts[0])")
			default:
				return nil
			}
		}
	}

	// MARK: - Fragment paths: `#map=15/47.94/18.70`, `#15/47.94/18.70`

	/// OpenStreetMap's `#map=Z/LAT/LON` and the MapLibre/Leaflet `#Z/LAT/LON` hash.
	///
	/// Zoom-first is a genuine cross-site standard here rather than a per-app fact, which is what
	/// makes reading it without knowing the site defensible.
	private static func fragmentPath(_ fragment: String) -> MapLocationReading? {
		var body = fragment
		if let range = body.range(of: "map=") { body = String(body[range.upperBound...]) }
		body = body.split(separator: "&").first.map(String.init) ?? body

		// Layer and display fields follow the viewport on several sites
		// (`#14.00/39.73/-74.22/us3depShade1/0.00/0.00`), so only the leading run of numbers is the
		// viewport; everything from the first non-numeric segment on is somebody else's state.
		var leading: [String] = []
		for segment in body.split(separator: "/").map(String.init) {
			guard strictDouble(segment) != nil else { break }
			leading.append(segment)
		}
		guard leading.count >= 3 else { return nil }

		let numbers = leading.prefix(3).compactMap(strictDouble)
		guard numbers.count == 3, zoomRange.contains(numbers[0]) else { return nil }
		// A viewport carries decimals. An all-integer triple is far more likely to be an id, a
		// version, or a set of counters that happens to sit in range.
		guard leading.prefix(3).contains(where: { $0.contains(".") }) else { return nil }
		guard let coordinate = MapCoordinate(latitude: numbers[1], longitude: numbers[2]) else { return nil }
		return MapLocationReading(
			coordinate: coordinate,
			zoom: numbers[0],
			source: .urlHashPath,
			rawText: "\(leading[1]), \(leading[2])"
		)
	}

	// MARK: - Path segments: `/@50.0755,14.4378,15z`

	/// The `@LAT,LON,Nz` form Google Maps and several clones put in the path rather than the query.
	private static func atPath(_ url: URL) -> MapLocationReading? {
		guard let segment = url.path.split(separator: "/").first(where: { $0.hasPrefix("@") }) else { return nil }
		let parts = segment.dropFirst().split(separator: ",").map(String.init)
		guard parts.count >= 2,
		      let latitude = strictDouble(parts[0]),
		      let longitude = strictDouble(parts[1]),
		      let coordinate = MapCoordinate(latitude: latitude, longitude: longitude)
		else { return nil }
		var zoom: Double?
		if parts.count > 2, parts[2].hasSuffix("z"), let value = strictDouble(String(parts[2].dropLast())) {
			zoom = zoomRange.contains(value) ? value : nil
		}
		return MapLocationReading(
			coordinate: coordinate,
			zoom: zoom,
			source: .urlHashPath,
			rawText: "\(parts[0]), \(parts[1])"
		)
	}

	// MARK: - Coordinate reference system

	/// Whether the URL names a projection that is not WGS-84.
	///
	/// This is the guard that makes admitting `x`/`y` into the vocabulary survivable. Web Mercator
	/// and national grids are usually far outside ±180 and get rejected on range alone — but not
	/// always: an EPSG:3857 view near the origin (`x=100&y=50`, metres off West Africa) is inside
	/// the geographic range and would otherwise be saved as 50°N 100°E.
	private static func carriesForeignCRSMarker(_ url: URL) -> Bool {
		let markers = crsMarkers(url)
		guard markers.isEmpty.not else { return false }
		return markers.allSatisfy(isWGS84Marker).not
	}

	/// Whether the URL explicitly states that its numbers are geographic.
	private static func declaresWGS84(_ url: URL) -> Bool {
		let markers = crsMarkers(url)
		return markers.isEmpty.not && markers.allSatisfy(isWGS84Marker)
	}

	private static func crsMarkers(_ url: URL) -> [String] {
		let names: Set<String> = ["srs", "crs", "projection", "proj", "epsg", "spatialreference", "sr"]
		// The SAME fragment treatment the coordinate scan uses. Reading the raw fragment here missed
		// a marker behind a router path — `#/map?srs=EPSG:3857&x=100&y=50` parsed as a single field
		// named `/map?srs`, so the guard never fired and 100/50 metres were stored as degrees.
		let pairs = keyValues(url.query)
			+ keyValues(queryPortion(of: url.fragment.map(percentDecoded) ?? ""))
		return pairs
			.filter { names.contains($0.name.lowercased()) }
			.map { $0.value.lowercased() }
	}

	private static func isWGS84Marker(_ value: String) -> Bool {
		let normalized = value.replacingOccurrences(of: " ", with: "")
		return ["epsg:4326", "4326", "crs:84", "ogc:crs84", "urn:ogc:def:crs:ogc:1.3:crs84",
		        "wgs84", "epsg:104326"].contains(normalized)
	}

	// MARK: - Primitives

	/// The parameter part of a fragment, dropping any router path in front of it.
	private static func queryPortion(of fragment: String) -> String {
		guard let mark = fragment.lastIndex(of: "?") else { return fragment }
		return String(fragment[fragment.index(after: mark)...])
	}

	/// Splits `a=1&b=2` without treating the whole thing as a URL, so it works on a fragment too.
	private static func keyValues(_ raw: String?) -> [(name: String, value: String)] {
		guard let raw, raw.isEmpty.not else { return [] }
		return raw.split(separator: "&").compactMap { field in
			let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
			guard parts.count == 2 else { return nil }
			return (name: percentDecoded(parts[0]), value: percentDecoded(parts[1]))
		}
	}

	private static func percentDecoded(_ value: String) -> String {
		value.removingPercentEncoding ?? value
	}

	/// A decimal number and nothing else.
	///
	/// `Double("1e5")`, `Double("inf")` and `Double("nan")` all succeed, and none of them is a
	/// coordinate — the same trap `CoordinateText` guards against.
	private static func strictDouble(_ raw: String) -> Double? {
		let trimmed = raw.trimmingCharacters(in: .whitespaces)
		guard trimmed.isEmpty.not,
		      trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
		      let value = Double(trimmed), value.isFinite
		else { return nil }
		return value
	}
}
