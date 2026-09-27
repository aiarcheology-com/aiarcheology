//
//  NavigationMap.swift
//  HeadlessKit
//
//  AIA-0982, AIA-0983.
//

import Foundation

/// One edge of the navigation map: from the route that declares it to `to`.
public struct TransitionDeclaration: Codable, Hashable, Sendable {
	/// The action that takes this edge; `nil` when the app moves there on its own, such as from
	/// launching to home once it is ready.
	public let action: String?
	public let to: Route
	/// One line saying when this edge applies.
	public let condition: String

	public init(action: String?, to: Route, condition: String) {
		self.action = action
		self.to = to
		self.condition = condition
	}
}

/// A route of the app and the transitions that can leave it.
public struct RouteDeclaration: Codable, Hashable, Sendable {
	public let route: Route
	public let summary: String
	public let transitions: [TransitionDeclaration]

	public init(route: Route, summary: String, transitions: [TransitionDeclaration] = []) {
		self.route = route
		self.summary = summary
		self.transitions = transitions
	}
}

/// Every route an app has and the transitions that are **possible** between them, each under its
/// condition. It describes what can happen, never what the current screen offers now: that is what
/// the live actions say.
public struct NavigationMap: Codable, Hashable, Sendable {

	public let routes: [RouteDeclaration]

	/// No declaration: nothing is known about the app's routes, so nothing is rejected.
	public static let empty = NavigationMap(routes: [])

	public init(routes: [RouteDeclaration]) {
		self.routes = routes
	}

	public var isEmpty: Bool { routes.isEmpty }

	/// The declared routes, in declaration order.
	public var routeNames: [Route] { routes.map(\.route) }

	public func declaration(for route: Route) -> RouteDeclaration? {
		routes.first { $0.route == route }
	}

	/// Whether `from` declares a transition to `to` taken by `action`. The pair is what matters: an
	/// action renamed to an already-declared target is still undeclared.
	public func declares(action: String, from: Route, to: Route) -> Bool {
		declaration(for: from)?.transitions.contains { $0.action == action && $0.to == to } ?? false
	}

	/// The declared route closest to `text`, for a "did you mean" hint; `nil` for an empty map.
	public func closest(to text: String) -> Route? {
		Self.closest(to: text, among: routeNames)
	}

	/// Why `route` is rejected, in the wording every reporter of an unknown route uses.
	public func unknownRouteMessage(_ route: String) -> String {
		Self.unknownRouteMessage(route, known: routeNames)
	}

	// MARK: - Without a map

	/// The route in `known` closest to `text` by edit distance, ignoring case; ties go to the earlier
	/// one. `nil` when `known` is empty.
	public static func closest(to text: String, among known: [Route]) -> Route? {
		let target = Array(text.lowercased())
		var best: (route: Route, distance: Int)?
		for route in known {
			let distance = editDistance(target, Array(route.rawValue.lowercased()))
			if let best, distance >= best.distance { continue }
			best = (route, distance)
		}
		return best?.route
	}

	/// `unknown route 'hme'; did you mean 'home'? (known: launching, home, …)`
	public static func unknownRouteMessage(_ route: String, known: [Route]) -> String {
		"unknown route '\(route)'; \(suggestion(for: route, known: known))"
	}

	/// `did you mean 'home'? (known: launching, home, …)` — the part of every unknown-route message
	/// that helps fix it.
	public static func suggestion(for route: String, known: [Route]) -> String {
		let list = "(known: \(known.map(\.rawValue).joined(separator: ", ")))"
		guard let closest = closest(to: route, among: known) else { return list }
		return "did you mean '\(closest)'? \(list)"
	}

	/// Levenshtein distance, one row at a time.
	private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
		guard a.isEmpty == false else { return b.count }
		guard b.isEmpty == false else { return a.count }
		var previous = Array(0...b.count)
		var current = [Int](repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			current[0] = i
			for j in 1...b.count {
				let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
				current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
			}
			swap(&previous, &current)
		}
		return previous[b.count]
	}
}
