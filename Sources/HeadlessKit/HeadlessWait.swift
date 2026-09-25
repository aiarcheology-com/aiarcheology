//
//  HeadlessWait.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// Waiting for a condition, for sessions and for action handlers that must return only once their
/// effect has landed.
public enum HeadlessWait {

	/// Re-evaluates `condition` until it holds or `timeout` passes.
	///
	/// - Returns: `true` when the condition held, `false` on timeout. The timeout is an upper bound
	///   on a named condition, never the thing waited for.
	/// - Throws: whatever `condition` throws, and `CancellationError` when the task is cancelled.
	@MainActor
	public static func until(
		timeout: Duration,
		pollInterval: Duration = .milliseconds(50),
		_ condition: @MainActor () throws -> Bool
	) async throws -> Bool {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while true {
			if try condition() { return true }
			guard clock.now < deadline else { return false }
			try await Task.sleep(for: min(pollInterval, deadline - clock.now))
		}
	}
}
