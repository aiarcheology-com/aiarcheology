//
//  MapParserArming.swift
//  AI Archeology
//
//  The one place that decides whether the map-location parser may touch a page (AIA-0821).
//

import Foundation

/// Whether the map-location parser is allowed to run on a given page.
///
/// ## Why this type exists
/// AIA-0817 injects a script into every page at document start. During its development that script
/// broke real sites outright — they rendered nothing at all. Those specific causes are fixed, but
/// the guarantee was *by construction and care*, and the user's browser is what is at stake. This
/// is the design half of the promise: the parser answers to a switch, and to an automatic breaker,
/// before it is allowed near a page.
///
/// The governing principle, from the ticket: **if the parser fails, it must fail so the page is
/// still usable.** A finding with no coordinate is a small loss. A page that will not render is the
/// product not working.
///
/// ## Three ways to be disarmed, one place to ask
/// The alternative — each caller checking the launch argument, then the setting, then the breaker —
/// is three chances to check two of them. `MapLocationProbe` had exactly one of the three before
/// this ticket, so the developer switch worked and nothing else could.
///
/// One honest exception: `MapLocationProbe.run` still checks the launch argument itself. That check
/// is now redundant — the resolver decides whether to build a probe at all — and it is kept as
/// defence in depth for the one switch whose whole purpose is to answer "was it us?" when something
/// has gone wrong enough that a developer is bisecting.
///
/// ## Session-scoped by design
/// Nothing here persists. A tripped host is forgotten at relaunch, so a site that broke once because
/// of a transient failure is not condemned forever, and a genuinely incompatible one costs the user
/// a single reload per session. Persisting it would need an eviction policy, a privacy story for a
/// list of visited hosts on disk, and a way for a user to clear it — for a list whose natural
/// lifetime is one session anyway.
///
/// `@MainActor` because it is read on the navigation path and written from web-view callbacks, both
/// of which are already main-bound. It is not an `ObservableObject`: nothing renders from it, and
/// the values it reads are observed at their own sources.
@MainActor
final class MapParserArming {

	private let settings: Settings

	/// Hosts whose pages failed with our script injected, for this session only.
	///
	/// One set, not two. A first draft kept a second set for "hosts whose reload has been spent", on
	/// the theory that they answer different questions — but every write inserted into both and
	/// nothing ever removed from either, so they could not differ. `insert` already reports whether
	/// the host was new, which is the same answer the second set was there to give.
	private var trippedHosts: Set<String> = []

	init(settings: Settings) {
		self.settings = settings
	}

	/// Whether the parser may run on `url`.
	///
	/// Ordered cheapest-first, but every branch is a hard no: this is not a score.
	func isArmed(for url: URL?) -> Bool {
		// The developer's bisecting switch (AIA-0817) still wins over everything.
		guard AppEnvironment.isMapLocationParserDisabled.not else { return false }
		guard settings.readMapPositionFromPages else { return false }
		// A URL with no host — a `file://` fixture, `about:blank` — cannot be tripped, because the
		// breaker has nothing to key on. Reaching this line means the switch and the launch argument
		// have already said yes, so only the BREAKER is unable to disarm a host-less URL; it is not
		// armed unconditionally. That matters because the harness pages the UI tests load are exactly
		// this case, and a breaker that could disarm them would make the feature untestable through
		// the app.
		guard let host = Self.key(for: url) else { return true }
		return trippedHosts.contains(host).not
	}

	/// Records that a page on `host` failed with the parser armed.
	///
	/// - Returns: `true` when this host may be reloaded — that is, on the FIRST trip for it. The
	///   caller gets one automatic reload per host per session and no more. Returning the decision
	///   from the same call that records the trip is deliberate: a caller that asked "should I
	///   reload?" separately from "remember this failure" could do one without the other.
	@discardableResult
	func recordFailure(host: String?) -> Bool {
		guard let key = Self.key(forHost: host) else { return false }
		// `inserted` is false when the host is already present, which is precisely "we have already
		// spent this host's reload".
		return trippedHosts.insert(key).inserted
	}

	/// Whether `host` has been tripped this session. Diagnostics and tests; the navigation path asks
	/// ``isArmed(for:)``.
	func hasTripped(host: String?) -> Bool {
		guard let key = Self.key(forHost: host) else { return false }
		return trippedHosts.contains(key)
	}

	// MARK: - The trip condition

	/// Whether the evidence gathered about one document means the parser should be disarmed for its
	/// site (AIA-0821).
	///
	/// A free function of its inputs, deliberately: the coordinator that gathers the evidence holds
	/// it in private per-document state that no test can reach, and a rule that can only be
	/// exercised by driving a real web view through a real failure is a rule nobody checks. Each
	/// term earns its place:
	///
	/// - **`armedForDocument`** — a page that rendered nothing while the parser was switched off is
	///   a broken page, not a page we broke. Disarming there teaches nothing and costs a coordinate.
	/// - **`mainFrameErrors > 0`** — on its own this is worthless evidence, and that is the point of
	///   requiring the rest: the page-diagnostics listener is *capturing*, so it counts failed
	///   sub-resource loads, and a healthy page with one 404 image reports an error.
	/// - **`renderedNothing`** — likewise worthless alone, being the ordinary state of an
	///   application shell, which is why the measurement behind it looks twice before believing it.
	///
	/// The conjunction is the shape of the failure this exists for: a bundle that threw on start-up
	/// and left the page with nothing on it.
	static func shouldDisarm(armedForDocument: Bool, mainFrameErrors: Int, renderedNothing: Bool) -> Bool {
		armedForDocument && mainFrameErrors > 0 && renderedNothing
	}

	// MARK: - Host keys

	/// The key a host is remembered under: case-folded, and nothing else.
	///
	/// Deliberately NOT stripping `www.` or any other prefix. Host equality here only has to be
	/// consistent with itself — the same site trips and is then suppressed — and every normalisation
	/// beyond case is a rule invented without a failure behind it. `www.example.com` and
	/// `example.com` are different hosts to WebKit; treating them as one would suppress a site the
	/// breaker never observed failing.
	static func key(for url: URL?) -> String? {
		key(forHost: url?.host)
	}

	static func key(forHost host: String?) -> String? {
		guard let host, host.isEmpty.not else { return nil }
		return host.lowercased()
	}
}
