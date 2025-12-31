//
//  SentryThrottleDiagnostics.swift
//  AI Archeology
//
//  DEBUG-only UI can read this to display current throttling counters.
//

import Foundation
import OSLog

struct SentryThrottleDiagnosticsSnapshot: Sendable {
	var config: SentryThrottleConfig
	var stats: SentryThrottleStats
}

enum SentryThrottleDiagnostics {
	private static let lock = OSAllocatedUnfairLock<(@Sendable () -> SentryThrottleDiagnosticsSnapshot)?>(initialState: nil)
	
	/// Install a provider. Safe to call multiple times; latest wins.
	static func install(provider: @escaping @Sendable () -> SentryThrottleDiagnosticsSnapshot) {
		lock.withLock { state in
			state = provider
		}
	}
	
	static func snapshot() -> SentryThrottleDiagnosticsSnapshot? {
		lock.withLock { state in
			state?()
		}
	}
}
