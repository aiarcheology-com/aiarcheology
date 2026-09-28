//
//  Transitions.swift
//  HeadlessKit
//
//  AIA-0994.
//

import Foundation

/// Whether the session also accepts the app's own moves after an action (AIA-0994).
public enum AppMoves: String, Sendable, CaseIterable {
	/// An action may land one move on the app's own past where it declares: the paywall arriving
	/// while `open-drawer` runs, a sync raising a question as a sheet closes.
	case oneHop
	/// Only what the action declares. For auditing a map: every failure is then a missing
	/// declaration or a race the one hop would have absorbed.
	case off
}

/// The routes an action may land on, by the rule in `specification/HEADLESS.md` (AIA-0994).
///
/// Let hop1(S) be the targets of the map's action-less edges out of the routes in S — **one** hop:
/// a transitive closure would accept `drawer.close` doing nothing, via home → paywall → drawer.
/// 1. The action declares `navigatesTo` t: {t} ∪ hop1({t}), minus the origin.
/// 2. Otherwise the map declares edges for (origin, action): their targets ∪ hop1(targets), minus the
///    origin.
/// 3. Otherwise: {origin} ∪ hop1({origin}) — an action without an edge stays on its screen.
///
/// A declared transition that does not move always fails. With no map, only a set `navigatesTo`
/// is checked, exactly, as before maps existed.
struct AcceptedLandings: Equatable {
	/// What the action declares, in map order; empty when it declares nothing (rule 3).
	let declared: [Route]
	/// The origin, when the action declares nothing and so stays (rule 3).
	let staysOn: Route?
	/// What the app's own moves add, in map order.
	let appMoves: [Route]
	let accepted: Set<Route>

	/// `nil` when nothing is checked: no map and no `navigatesTo`.
	init?(action: ActionSpec, origin: Route, map: NavigationMap, appMoves mode: AppMoves) {
		if map.isEmpty {
			guard let target = action.navigatesTo else { return nil }
			declared = [target]
			staysOn = nil
			appMoves = []
			accepted = [target]
			return
		}
		let base: [Route]
		if let target = action.navigatesTo {
			base = [target]
			staysOn = nil
		} else {
			let targets = map.targets(of: action.name, from: origin)
			if targets.isEmpty {
				base = [origin]
				staysOn = origin
			} else {
				base = targets
				staysOn = nil
			}
		}
		let hop = mode == .oneHop ? map.appMoves(from: Set(base)) : []
		var accepted = Set(base).union(hop)
		if staysOn == nil {
			accepted.remove(origin)
		}
		self.accepted = accepted
		declared = staysOn == nil ? map.ordered(Set(base)) : []
		appMoves = map.ordered(accepted.subtracting(base))
	}
}
