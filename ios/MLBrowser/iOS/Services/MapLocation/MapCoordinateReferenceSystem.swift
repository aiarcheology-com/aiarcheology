//
//  MapCoordinateReferenceSystem.swift
//  AI Archeology
//
//  Naming the coordinate system a map reports, so a projected position can be recorded as itself
//  rather than discarded (AIA-0817).
//

import Foundation

/// A readable name for the coordinate system an EPSG code identifies.
///
/// ## Why a projected coordinate is worth recording
/// A map on a national grid — the Czech S-JTSK, the Swiss LV95, a UTM zone — knows exactly where it
/// is looking. Insisting on WGS-84 would throw that away and record nothing, which is strictly worse
/// than recording the real position and saying which system it is in. The user can read
/// `S-JTSK (EPSG:5514): -828738.04, -1031271.56` and know both where it is and what it is.
///
/// ## Why we still convert nothing
/// The numbers are stored exactly as the map reported them. Re-projecting a national grid is
/// genuinely hard — Křovák is an oblique conformal conic — and doing it wrong produces a confident,
/// plausible, wrong place. Naming the system costs nothing and cannot be wrong in that way.
enum MapCoordinateReferenceSystem {

	/// Codes worth spelling out, because a reader recognises the name and not the number.
	///
	/// Keyed on EPSG codes, which are an international registry — not on any site. An unlisted code
	/// still gets recorded, just as `EPSG:<code>`.
	private static let names: [Int: String] = [
		4326: "WGS 84",
		4258: "ETRS89",
		3857: "Web Mercator",
		102_100: "Web Mercator",
		5514: "S-JTSK",
		102_067: "S-JTSK",
		2065: "S-JTSK Ferro",
		2056: "LV95",
		21781: "LV03",
		27700: "OSGB36",
		25831: "ETRS89 UTM31N",
		25832: "ETRS89 UTM32N",
		25833: "ETRS89 UTM33N",
		25834: "ETRS89 UTM34N",
		32633: "WGS 84 UTM33N",
		32634: "WGS 84 UTM34N",
		3035: "ETRS89 LAEA",
		3034: "ETRS89 LCC",
		31287: "MGI Austria Lambert",
		28992: "Amersfoort RD",
		2154: "RGF93 Lambert-93",
		// Poland's national grid, on every ArcGIS 3.x geoportal there (AIA-0828).
		2180: "PUWG 1992",
		3067: "ETRS89 TM35FIN",
		3006: "SWEREF99 TM"
	]

	/// Whether a code identifies plain geographic degrees.
	///
	/// Those are already latitude and longitude, so they belong in the ordinary WGS-84 path rather
	/// than being labelled as an exotic system.
	static func isGeographic(_ code: Int) -> Bool {
		code == 4326 || code == 4258 || code == 4269 // WGS 84, ETRS89, NAD83
	}

	/// Esri identifiers that are not EPSG codes, mapped to the EPSG code they mean.
	///
	/// ArcGIS reports its own WKIDs, and some have no EPSG equivalent at all. Writing
	/// `EPSG:102100` into a finding records an identifier that does not exist in the registry —
	/// someone looking it up later finds nothing.
	private static let esriAliases: [Int: Int] = [
		102_100: 3857,     // Esri's Web Mercator
		102_067: 5514      // Esri's S-JTSK / Krovak East North
	]

	/// The label written in front of a projected coordinate in the finding's GPS field.
	///
	/// An unrecognised Esri WKID is labelled `WKID:` rather than `EPSG:`, because claiming the wrong
	/// authority is worse than naming the right one.
	static func label(for code: Int?) -> String {
		guard let code else { return "map" }
		let resolved = esriAliases[code] ?? code
		if let name = names[resolved] { return "\(name) (EPSG:\(resolved))" }
		// EPSG codes are registered below 32767; anything above is an Esri-only identifier.
		return resolved > 32_767 ? "WKID:\(resolved)" : "EPSG:\(resolved)"
	}
}
