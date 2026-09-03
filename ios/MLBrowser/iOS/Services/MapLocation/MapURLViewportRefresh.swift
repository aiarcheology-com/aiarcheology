//
//  MapURLViewportRefresh.swift
//  AI Archeology
//
//  Making a stale viewport in the URL current again, using the live map (AIA-0817).
//

import Foundation

/// Rewrites viewport numbers a URL already carries with the values the live map currently holds.
///
/// ## The problem this solves
/// Some map apps never touch the address bar while you pan. Their URL keeps whatever viewport you
/// arrived with, so every finding saved on such a site records the same place no matter where the
/// user actually looked. Those same apps typically offer a "copy link to this view" button, which
/// proves the app *can* serialise its current view into exactly that parameter — it simply does not
/// do so continuously.
///
/// ## Why this is not per-site code
/// Nothing here knows any app's URL format. The rule is entirely structural: *if* the URL already
/// contains a recognised viewport parameter, and the live map reports a viewport with the same
/// shape, replace the numbers in place. The app defined the format by putting it there; this only
/// refreshes its contents. A site that carries no such parameter is left untouched.
///
/// ## Why the numbers are not converted
/// They are written back in the view's own coordinate system, exactly as the map reported them —
/// the same values the app's own share button would produce. Converting them would both be
/// arithmetic this design refuses and produce a URL the app could not read back.
enum MapURLViewportRefresh {

	/// Parameter names that hold a viewport rectangle, as `xmin,ymin,xmax,ymax`.
	private static let extentNames: Set<String> = ["extent", "bbox", "box"]
	/// Parameter names that hold a viewport centre, as two numbers.
	///
	/// The order differs between ecosystems — OpenLayers and ArcGIS write longitude first, Google
	/// and `ll`/`pos` write latitude first — and the live map always reports `x, y`. Writing one
	/// convention into the other transposes the pair, which is the single worst thing this file
	/// could do, so the order is chosen by comparison rather than assumed. See ``ordered(_:like:)``.
	private static let latitudeFirstCentreNames: Set<String> = ["ll", "pos", "loc"]
	private static let longitudeFirstCentreNames: Set<String> = ["center", "centre", "c"]
	private static var centreNames: Set<String> { latitudeFirstCentreNames.union(longitudeFirstCentreNames) }

	/// A URL whose viewport parameter reflects where the map is looking now.
	///
	/// Returns `nil` when nothing could be refreshed, so a caller can tell "unchanged" from
	/// "changed", and never silently substitutes a URL it did not actually improve.
	static func refreshed(
		url: URL,
		extent: [Double]?,
		center: [Double]?,
		geographic: (latitude: Double, longitude: Double)? = nil,
		zoom: Double? = nil,
		mayRefreshFragment: Bool = true
	) -> URL? {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

		// Fragment viewports first: an app that keeps its view there usually keeps nothing in the
		// query, and a finding whose URL opens on a whole globe records the place about as well as
		// no URL at all.
		//
		// Only for a page observed maintaining its own URL, though. demotiles.maplibre.org neither
		// reads nor writes its hash — opening `#3.38/54.22/-177.33` lands on the default view, and
		// panning never changes it — so writing a viewport there produces a link that looks precise
		// and goes nowhere. A page that rewrites its hash as you pan is using it as state, and is
		// the case this helps. Query parameters carry no such doubt: those are what a site's own
		// share action produces.
		if mayRefreshFragment,
		   let updated = refreshedFragment(components, geographic: geographic, zoom: zoom, center: center) {
			return updated
		}

		if let extent, extent.count == 4, extent.allSatisfy(\.isFinite),
		   let updated = replacing(components, names: extentNames, arity: 4, values: extent) {
			return updated
		}
		if let center, center.count == 2, center.allSatisfy(\.isFinite),
		   let updated = replacing(components, names: centreNames, arity: 2, values: center) {
			return updated
		}
		return nil
	}

	/// Whether a set of numbers is in the geographic range.
	///
	/// Used as a units check, not as validation: a parameter already holding degrees must not be
	/// overwritten with metres, and vice versa. This is the same class of error the inference tier
	/// guards against with a CRS marker — a viewport written in the wrong units produces a
	/// confident, wrong link, on the field this ticket calls the must-have.
	static func looksGeographic(_ values: [Double]) -> Bool {
		guard values.isEmpty.not else { return false }
		return values.allSatisfy { abs($0) <= 180 }
			&& values.enumerated().allSatisfy { index, value in
				// In an x,y or minx,miny,maxx,maxy layout the odd positions are latitudes.
				index.isMultiple(of: 2) ? abs(value) <= 180 : abs(value) <= 90
			}
	}

	/// Refuses a replacement whose units plainly differ from what the parameter already held.
	static func unitsAgree(existing: [Double], replacement: [Double]) -> Bool {
		guard existing.isEmpty.not, replacement.isEmpty.not else { return false }
		return looksGeographic(existing) == looksGeographic(replacement)
	}

	/// Puts a two-number pair in the order its parameter name defines.
	///
	/// The live map always reports `x, y`. `ll`, `pos` and `loc` are latitude-first by convention;
	/// `center`, `centre` and `c` are longitude-first in the OpenLayers and ArcGIS ecosystems that
	/// use them. Writing one into the other transposes the pair into a valid-looking URL pointing
	/// somewhere else.
	///
	/// An earlier version inferred the order by whichever arrangement landed nearer the values
	/// already in the URL. That works for a small pan and fails for a large one: with `ll=10,80`
	/// stale and the map now at `x,y = -70,20`, proximity picks `-70,20` — exactly backwards. A name
	/// with no known convention is refused rather than guessed.
	static func ordered(_ values: [Double], for name: String) -> [Double]? {
		guard values.count == 2 else { return nil }
		let key = name.lowercased()
		if latitudeFirstCentreNames.contains(key) { return [values[1], values[0]] }
		if longitudeFirstCentreNames.contains(key) { return values }
		return nil
	}

	private static func replacing(
		_ components: URLComponents,
		names: Set<String>,
		arity: Int,
		values: [Double]
	) -> URL? {
		var components = components

		/// The replacement text, in the order this parameter's name defines. `nil` when the name has
		/// no known convention, which refuses the refresh rather than risking a transposition.
		func replacement(for name: String, keeping existing: [String]) -> String? {
			guard arity == 2 else { return values.map(format).joined(separator: ",") }
			guard let arranged = ordered(values, for: name) else { return nil }
			// Anything past the pair — a zoom, usually — is the app's own state and is kept.
			let trailing = existing.count > 2 ? existing.dropFirst(2) : []
			return (arranged.map(format) + trailing).joined(separator: ",")
		}

		if var items = components.percentEncodedQueryItems,
		   let index = items.firstIndex(where: {
			   matches(URLQueryItem(name: $0.name, value: $0.value?.removingPercentEncoding ?? $0.value),
			           names: names, arity: arity)
		   }) {
			// Written back with literal commas rather than `%2C`. Both decode identically, but the
			// apps that use this format write plain commas, and a link a user may paste elsewhere
			// should look like the one the site's own share button produces.
			let currentValues = (items[index].value?.removingPercentEncoding ?? items[index].value ?? "")
				.split(separator: ",")
				.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
			let currentParts = (items[index].value?.removingPercentEncoding ?? items[index].value ?? "")
				.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
			guard unitsAgree(existing: Array(currentValues.prefix(2)), replacement: values) else { return nil }
			guard let text = replacement(for: items[index].name, keeping: currentParts) else { return nil }
			items[index] = URLQueryItem(name: items[index].name, value: text)
			components.percentEncodedQueryItems = items
			return components.url
		}

		// Several apps keep the viewport in the fragment instead.
		if let fragment = components.fragment,
		   let updated = replacingInQueryString(fragment, names: names, arity: arity, values: values,
		                                        replacement: { replacement(for: $0, keeping: $1) }) {
			components.fragment = updated
			return components.url
		}
		return nil
	}

	/// Rewrites a viewport held in the fragment rather than in a named parameter.
	///
	/// Two shapes, both open grammars rather than any site's invention:
	///
	/// - `#Z/LAT/LON` — the MapLibre and OpenStreetMap hash. Refreshed only from a geographic
	///   reading, since the grammar is degrees by definition.
	/// - `#{"center":[x,y],"zoom":n}` — a JSON view state, as OpenLayers applications write. The
	///   centre goes back in the map's own coordinate system, exactly as the app wrote it.
	///
	/// Everything else in the fragment is preserved: an app keeps its layers and overlays there too,
	/// and a link that restored the view while losing the layers would be a poor trade.
	private static func refreshedFragment(
		_ components: URLComponents,
		geographic: (latitude: Double, longitude: Double)?,
		zoom: Double?,
		center: [Double]?
	) -> URL? {
		var components = components
		guard let fragment = components.fragment, fragment.isEmpty.not else { return nil }

		// --- JSON view state ---
		if fragment.hasPrefix("{") || fragment.hasPrefix("%7B") {
			let decoded = fragment.removingPercentEncoding ?? fragment
			guard let data = decoded.data(using: .utf8),
			      var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			      let existing = object["center"] as? [Double], existing.count == 2,
			      let center, center.count == 2,
			      unitsAgree(existing: existing, replacement: center)
			else { return nil }
			object["center"] = center
			if let zoom, object["zoom"] != nil { object["zoom"] = zoom }
			guard let encoded = try? JSONSerialization.data(withJSONObject: object),
			      let text = String(data: encoded, encoding: .utf8)
			else { return nil }
			components.fragment = text
			return components.url
		}

		// --- `#Z/LAT/LON`, with anything after it left alone ---
		guard let geographic else { return nil }
		var body = fragment
		var prefix = ""
		if let range = body.range(of: "map=") {
			prefix = String(body[..<range.upperBound])
			body = String(body[range.upperBound...])
		}
		var trailer = ""
		if let amp = body.firstIndex(of: "&") {
			trailer = String(body[amp...])
			body = String(body[..<amp])
		}
		let segments = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard segments.count >= 3,
		      segments.prefix(3).allSatisfy({ Double($0) != nil }),
		      let existingZoom = Double(segments[0]),
		      let existingLatitude = Double(segments[1]),
		      let existingLongitude = Double(segments[2])
		else { return nil }

		// The same guards the inference tier applies, because three numbers separated by slashes is
		// also what a date route looks like: `#2024/05/01` would otherwise be rewritten into a
		// viewport the moment any live reading existed.
		guard (0...24).contains(existingZoom),
		      abs(existingLatitude) <= 90, abs(existingLongitude) <= 180,
		      segments.prefix(3).contains(where: { $0.contains(".") })
		else { return nil }

		var replaced = segments
		replaced[0] = format(zoom ?? existingZoom)
		replaced[1] = format(geographic.latitude)
		replaced[2] = format(geographic.longitude)
		components.fragment = prefix + replaced.joined(separator: "/") + trailer
		return components.url
	}

	/// Only a parameter that already holds the right number of numbers is a viewport.
	///
	/// This is what stops the rule touching `center=auto`, an id, or a name that happens to collide
	/// — the existing value has to look like the thing being replaced.
	private static func matches(_ item: URLQueryItem, names: Set<String>, arity: Int) -> Bool {
		guard names.contains(item.name.lowercased()), let value = item.value else { return false }
		let parts = value.split(separator: ",").map(String.init)
		guard parts.allSatisfy({ Double($0.trimmingCharacters(in: .whitespaces)) != nil }) else { return false }
		// A centre may carry a trailing zoom — `pos=lat,lon,zoom` is the common form — so an exact
		// arity match would refuse the very grammar this is meant to refresh. The extra member is
		// preserved rather than replaced.
		return arity == 2 ? (parts.count == 2 || parts.count == 3) : parts.count == arity
	}

	private static func replacingInQueryString(
		_ raw: String,
		names: Set<String>,
		arity: Int,
		values: [Double],
		replacement: (String, [String]) -> String?
	) -> String? {
		var changed = false
		let fields = raw.split(separator: "&", omittingEmptySubsequences: false).map { field -> String in
			let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
			guard parts.count == 2, changed == false else { return String(field) }
			let item = URLQueryItem(name: parts[0], value: parts[1].removingPercentEncoding ?? parts[1])
			guard matches(item, names: names, arity: arity) else { return String(field) }
			let currentValues = (item.value ?? "").split(separator: ",")
				.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
			let currentParts = (item.value ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
			guard unitsAgree(existing: Array(currentValues.prefix(2)), replacement: values) else { return String(field) }
			guard let text = replacement(parts[0], currentParts) else { return String(field) }
			changed = true
			return "\(parts[0])=\(text)"
		}
		return changed ? fields.joined(separator: "&") : nil
	}

	/// Enough precision for a projected metre grid, without a float artefact tail.
	///
	/// The app parses these back, so they have to be plain decimals: no exponent, no locale comma.
	private static func format(_ value: Double) -> String {
		var text = String(format: "%.6f", value)
		if text.contains(".") {
			while text.hasSuffix("0") { text.removeLast() }
			if text.hasSuffix(".") { text.removeLast() }
		}
		return text
	}
}
