//
//  WebContentTerminationPolicy.swift
//  AI Archeology
//
//  AIA-0879: decides how a detection run answers a web content process that died under it.
//

import Foundation

/// Whether a web content process termination should merely interrupt detection or end the run.
///
/// ## Why this is not simply "stop"
/// A renderer can die for reasons that have nothing to do with us, and detection is the product.
/// Ending a run on the first termination costs the user their whole session for what may have been
/// a one-off. But a page that kills its renderer once usually does it again, and resuming into it
/// is the loop AIA-0879 was raised for: reload, detect, die, reload.
///
/// So the first termination on a site interrupts the run, and a second one on the SAME site inside
/// ``repeatWindow`` ends it. One strike per site, for the same reason ``MapParserArming`` gives a
/// site one reload: a transient failure must not condemn a site for the session.
///
/// ## Why ten minutes and not the recovery window
/// ``WebContentRecoveryPolicy/defaultWindow`` is 60 seconds, which is the right scale for "did this
/// recovery rung work". It is the wrong scale here. The terminations measured on the reported
/// device (AIA-0879) were 2m19s, 4m17s and 7m24s apart, so a 60-second escalation window would
/// never have fired and this type would have been dead code. A killed page needs minutes to load
/// and climb back to the memory it died at; the window has to outlast that climb.
///
/// Pure value type with no clock of its own — the caller passes `now` — so the escalation is
/// exhaustively unit-testable without waiting on real time, exactly as ``WebContentRecoveryPolicy``
/// is.
struct WebContentTerminationPolicy: Equatable {

	/// What detection should do about one termination.
	enum Response: Equatable {
		/// Hold detection until the replacement document has loaded, then carry on.
		case interrupt
		/// End the detection run and leave it ended.
		case endRun
	}

	/// How close together two terminations on one site have to be to count as a loop.
	static let defaultRepeatWindow: TimeInterval = 600

	private let repeatWindow: TimeInterval
	/// When each site last killed its renderer.
	///
	/// A map, not a single "last termination". Remembering only the most recent site meant an
	/// interleaving lost the strike that mattered: A dies, B dies, A dies again a minute later — B
	/// had overwritten A's record, so the repeat on A read as a first offence and the loop carried on
	/// (raised in review). Two failing sites at once is not exotic; an iframed portal is two hosts.
	///
	/// Bounded by age rather than by count: an entry older than ``repeatWindow`` can never produce
	/// `.endRun` again, so dropping it costs nothing and the map cannot grow beyond the sites that
	/// failed inside one window.
	private var lastTerminations: [String: Date] = [:]

	init(repeatWindow: TimeInterval = defaultRepeatWindow) {
		self.repeatWindow = repeatWindow
	}

	/// The answer to one termination, consuming the site's strike.
	///
	/// - Parameters:
	///   - host: the site whose renderer died, or `nil` when it cannot be attributed.
	///   - now: the caller's clock.
	mutating func response(host: String?, now: Date) -> Response {
		forgetExpired(asOf: now)
		guard let key = Self.key(forHost: host) else {
			// Nothing to key a repeat on — an `about:blank`, a `file://` fixture. Deliberately does
			// NOT arm the escalation: a site that cannot be identified cannot be shown to have
			// failed twice, and arming anyway would let two unrelated pages end a run between them.
			// The same trade `MapParserArming` makes for a host-less URL.
			return .interrupt
		}
		if let last = lastTerminations[key], Self.isWithin(repeatWindow, from: last, to: now) {
			// Cleared rather than kept. The run is ending, so whatever the user starts next begins
			// with a clean strike for this site — otherwise its first termination in the new run would
			// end that run instantly on the strength of the old one.
			lastTerminations[key] = nil
			return .endRun
		}
		lastTerminations[key] = now
		return .interrupt
	}

	/// Drops records that can no longer produce a repeat.
	///
	/// Also the bound on the map. A record from before the window is indistinguishable from no
	/// record as far as ``response(host:now:)`` is concerned, so forgetting it changes no answer.
	private mutating func forgetExpired(asOf now: Date) {
		lastTerminations = lastTerminations.filter { Self.isWithin(repeatWindow, from: $0.value, to: now) }
	}

	/// Whether `to` falls inside `window` after `from`.
	///
	/// The lower bound is not decoration: a clock moved backwards (a manual change, an NTP step)
	/// yields a negative interval, which a bare `< window` test would read as "these two happened
	/// close together" and end a run on one termination.
	private static func isWithin(_ window: TimeInterval, from: Date, to: Date) -> Bool {
		let elapsed = to.timeIntervalSince(from)
		return elapsed >= 0 && elapsed < window
	}

	/// The key a site is remembered under: case-folded, and nothing else.
	///
	/// Deliberately not stripping `www.` or any other prefix, for the reason ``MapParserArming``
	/// gives — host equality here only has to be consistent with itself, and every normalisation
	/// beyond case is a rule invented without a failure behind it.
	private static func key(forHost host: String?) -> String? {
		guard let host, host.isEmpty.not else { return nil }
		return host.lowercased()
	}
}
