//
//  FreeAccessExpirySeed.swift
//  AI Archeology
//
//  A free-access window that ends a set number of seconds after launch (AIA-0984).
//

import Foundation

#if DEBUG
/// Seeds a free-access window that ends `N` seconds after launch, so a test can watch the paywall
/// arrive mid-session through the app's own expiry path.
///
/// Nothing else reaches that moment in a test: a window lasts calendar days, and the UI tests' aged
/// seed (`freeAccessAnchorAgeDays`) starts one either open for days or already expired. Once the record is in place the
/// real machinery does the rest — `FreeAccessState.scheduleExpiry()` arms its wake-up at
/// `expiresAt`, and the re-evaluation it runs closes access for the root gate.
///
/// Used by `UITestLaunchConfiguration.freeAccessEndsInSeconds` and by the headless build's
/// `-headlessFreeAccessEndsIn`. `#if DEBUG` like ``EphemeralFreeAccessAnchorStore``: Release neither
/// contains nor honours it.
///
/// Removal: delete this file, both launch options, and the parity flow that sets them.
enum FreeAccessExpirySeed {

	/// The seconds a launch may ask for. The floor leaves a flow time to reach the screen it wants the
	/// paywall to cover; the ceiling keeps the window inside one calendar-day boundary, which is what
	/// keeps the record credible (see ``record(endingInSeconds:now:)``).
	static let allowedSeconds = 30...3600

	/// The record a seed writes: granted `now`, ending `seconds` later, its day-0 screen already shown.
	///
	/// `day0Shown` is `true` for the reason the UI tests' aged seed gives: a window that had never
	/// been explained owes its Welcome screen first, and the flow would meet that instead.
	///
	/// Credible by construction. `FreeAccessWindow.isCredible` bounds the grant to not-in-the-future
	/// and the claimed length to `0...maxCredibleGrantDays` calendar days from the grant's midnight;
	/// with `seconds` inside ``allowedSeconds`` that length is 0, or 1 when the window crosses
	/// midnight.
	static func record(endingInSeconds seconds: Int, now: Date) -> FreeAccessWindow.Record {
		FreeAccessWindow.Record(
			grantedAt: now,
			expiresAt: now.addingTimeInterval(TimeInterval(seconds)),
			maxObservedDate: now,
			day0Shown: true
		)
	}

	/// Why nothing was written.
	enum Skip: Equatable {
		/// A store already holds an anchor. A relaunch inside a scenario passes the option again, and
		/// the window it opened the first time must run on rather than restart.
		case anchorExists
		/// The durable store could not be read, so an anchor there cannot be ruled out.
		case durableStoreUnreadable
	}

	/// Writes ``record(endingInSeconds:now:)`` into the fast store — the key and encoding the UI
	/// tests' aged seed uses — when neither store holds an anchor. Otherwise both stores are left
	/// exactly as they are and the reason is logged.
	///
	/// Only the fast store is ever written. The next `FreeAccessAnchorService.reconciledWindow()`
	/// copies the record into the durable store, as it repairs any store missing the other's anchor:
	/// `FreeAccessWindow.credible` returns a credible record unchanged,
	/// `reanchoredIfGrantedInTheFuture` returns `nil` for a grant at `now`, and the settled record then
	/// differs from the absent durable one, so the service saves it there.
	///
	/// - Parameter durableStore: the durable half the composition root resolved, read only to rule an
	///   anchor out. `nil` where the caller knows it is empty — the UI tests' per-process
	///   ``EphemeralFreeAccessAnchorStore``.
	/// - Returns: the written record, or why none was written.
	@discardableResult
	static func seedWindowEnding(
		inSeconds seconds: Int,
		now: Date = Date(),
		fastStore: UserDefaults,
		durableStore: FreeAccessAnchorDurableStore?
	) -> Result<FreeAccessWindow.Record, Skip> {
		guard allowedSeconds.contains(seconds) else {
			fatalError("The free-access window must end \(allowedSeconds.lowerBound)...\(allowedSeconds.upperBound) seconds after launch, got \(seconds)")
		}
		let skip: Skip?
		if fastStore.object(forKey: FreeAccessAnchorService.defaultsKey) != nil {
			skip = .anchorExists
		} else {
			do {
				skip = try durableStore?.loadRecord() == nil ? nil : .anchorExists
			} catch {
				skip = .durableStoreUnreadable
			}
		}
		if let skip {
			LoggingPolicy.info("Free-access expiry seed skipped: \(skip)", logger: .state)
			return .failure(skip)
		}
		let record = record(endingInSeconds: seconds, now: now)
		UITestLaunchConfiguration.writeFreeAccessAnchor(
			record,
			to: fastStore,
			orTrap: "Could not encode the seeded free-access anchor"
		)
		return .success(record)
	}
}

extension FreeAccessExpirySeed.Skip: Error {}
#endif
