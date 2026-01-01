//
//  SentryEventGuard.swift
//  AI Archeology
//
//  Client-side Sentry event throttling + deduplication.
//  Intentionally does NOT import Sentry; callers provide an event signature.
//

import Foundation
import OSLog

enum SentryEventDropReason: String, Sendable {
	case disabled
	case duplicate
	case global_cap
	case session_cap
	case server_rate_limit
}

struct SentryEventGuardDecision: Sendable {
	var isAllowed: Bool
	var dropReason: SentryEventDropReason?
	
	/// If > 0, caller should attach this count to the next allowed event.
	var suppressedDuplicatesToReport: Int
}

struct SentryThrottleStats: Sendable, Equatable {
	var attempted: Int = 0
	var sent: Int = 0
	
	var droppedDuplicate: Int = 0
	var droppedGlobalCap: Int = 0
	var droppedSessionCap: Int = 0
	var droppedServerRateLimit: Int = 0
}

/// Synchronous, lock-protected guard for Sentry events.
///
/// Designed to be called from Sentry's synchronous `beforeSend` hook.
final class SentryEventGuard: @unchecked Sendable {
	
	private struct SignatureState {
		var windowStart: ContinuousClock.Instant
		var sentInWindow: Int
		
		/// Number of duplicates observed within the current window (allowed or dropped).
		var duplicateCounter: Int
		
		/// Duplicates suppressed since the last allowed event (to be reported on next allowed).
		var suppressedSinceLastAllowed: Int
	}
	
	private struct State: @unchecked Sendable {
		var config: SentryThrottleConfig
		var clock: ContinuousClock
		
		var stats: SentryThrottleStats = .init()
		var sessionAllowed: Int = 0
		
		/// Rolling list of allowed event instants (bounded by config.globalCapPerHour).
		var allowedInstants: [ContinuousClock.Instant] = []
		
		/// Global server backoff (if known).
		var serverMuteUntil: ContinuousClock.Instant?
		
		var lru: LRUCache<String, SignatureState> = .init(capacity: 200)
	}
	
	// MARK: - Logging
	
	private static let decisionLog = Logger(subsystem: "com.app.sentry-throttle", category: "decision")
	private static let rateLimitLog = Logger(subsystem: "com.app.sentry-throttle", category: "rate_limit")
	
	// MARK: - State
	
	private let lock = OSAllocatedUnfairLock<State>(initialState: State(config: .default, clock: ContinuousClock(), lru: .init(capacity: SentryThrottleConfig.default.signatureCacheLimit)))
	
	init(config: SentryThrottleConfig, clock: ContinuousClock = ContinuousClock()) {
		lock.withLock { state in
			state.config = config
			state.clock = clock
			state.lru.setCapacity(config.signatureCacheLimit)
		}
	}
	
	// MARK: - Public API
	
	func decide(signatureHex: String) -> SentryEventGuardDecision {
		lock.withLock { state in
			let now = state.clock.now
			return decideLocked(signatureHex: signatureHex, now: now, state: &state)
		}
	}
	
	/// Test-only entry point: allows deterministic time without sleeping.
	///
	/// Do not use from production code; prefer `decide(signatureHex:)`.
	func decide(signatureHex: String, now: ContinuousClock.Instant) -> SentryEventGuardDecision {
		lock.withLock { state in
			decideLocked(signatureHex: signatureHex, now: now, state: &state)
		}
	}
	
	private func decideLocked(signatureHex: String, now: ContinuousClock.Instant, state: inout State) -> SentryEventGuardDecision {
		state.stats.attempted += 1
			
			guard state.config.isEnabled else {
				state.stats.sent += 1
				state.sessionAllowed += 1
				return .init(isAllowed: true, dropReason: nil, suppressedDuplicatesToReport: 0)
			}
			
			// Server mute (if known)
			if let muteUntil = state.serverMuteUntil, now < muteUntil {
				state.stats.droppedServerRateLimit += 1
				logDrop(.server_rate_limit, signatureHex: signatureHex, extra: "muted_until=\(muteUntil)")
				return .init(isAllowed: false, dropReason: .server_rate_limit, suppressedDuplicatesToReport: 0)
			}
			
			// Session cap
			if state.sessionAllowed >= state.config.sessionCap {
				state.stats.droppedSessionCap += 1
				logDrop(.session_cap, signatureHex: signatureHex, extra: "session_cap=\(state.config.sessionCap)")
				return .init(isAllowed: false, dropReason: .session_cap, suppressedDuplicatesToReport: 0)
			}
			
			// Global cap (rolling 1h window)
			pruneGlobalWindow(state: &state, now: now)
			if state.allowedInstants.count >= state.config.globalCapPerHour {
				state.stats.droppedGlobalCap += 1
				logDrop(.global_cap, signatureHex: signatureHex, extra: "global_cap=\(state.config.globalCapPerHour)")
				return .init(isAllowed: false, dropReason: .global_cap, suppressedDuplicatesToReport: 0)
			}
			
			let windowDuration = state.config.perSignatureCooldown
			let burst = max(1, state.config.perSignatureBurst)
			let sampleN = state.config.sampleEveryNthDuplicate
			
			var suppressedToReport = 0
			var shouldAllow = false
			var shouldCountAsDuplicateDrop = false
			
			state.lru.withValue(forKey: signatureHex, createIfMissing: {
				SignatureState(windowStart: now, sentInWindow: 0, duplicateCounter: 0, suppressedSinceLastAllowed: 0)
			}) { entry in
				// Reset window if cooldown elapsed
				if entry.windowStart.duration(to: now) >= windowDuration {
					entry.windowStart = now
					entry.sentInWindow = 0
					entry.duplicateCounter = 0
					entry.suppressedSinceLastAllowed = 0
				}
				
				// Update duplicate counter (counts occurrences within window)
				entry.duplicateCounter += 1
				
				// Allow initial burst
				if entry.sentInWindow < burst {
					shouldAllow = true
				} else if sampleN >= 2, entry.duplicateCounter % sampleN == 0 {
					// Sampling: keep every Nth duplicate
					shouldAllow = true
				} else {
					shouldAllow = false
				}
				
				if shouldAllow {
					entry.sentInWindow += 1
					suppressedToReport = entry.suppressedSinceLastAllowed
					entry.suppressedSinceLastAllowed = 0
				} else {
					entry.suppressedSinceLastAllowed += 1
					shouldCountAsDuplicateDrop = true
				}
			}
			
			if shouldAllow {
				state.stats.sent += 1
				state.sessionAllowed += 1
				state.allowedInstants.append(now)
				return .init(isAllowed: true, dropReason: nil, suppressedDuplicatesToReport: suppressedToReport)
			}
			
			if shouldCountAsDuplicateDrop {
				state.stats.droppedDuplicate += 1
				logDrop(.duplicate, signatureHex: signatureHex, extra: "cooldown=\(windowDuration), burst=\(burst), sampleEvery=\(sampleN)")
				return .init(isAllowed: false, dropReason: .duplicate, suppressedDuplicatesToReport: 0)
			}
			
			// Fallback (should not happen)
			state.stats.droppedDuplicate += 1
			logDrop(.duplicate, signatureHex: signatureHex, extra: "unexpected_state")
			return .init(isAllowed: false, dropReason: .duplicate, suppressedDuplicatesToReport: 0)
	}
	
	func statsSnapshot() -> SentryThrottleStats {
		lock.withLock { $0.stats }
	}
	
	func configSnapshot() -> SentryThrottleConfig {
		lock.withLock { $0.config }
	}
	
	/// Updates the server-imposed rate limit backoff period.
	///
	/// This method is intended for integration with Sentry's `Retry-After` and `X-Sentry-Rate-Limits`
	/// headers when implementing custom transport layers. The Sentry SDK's built-in transport already
	/// respects these headers internally, so this method is currently unused but available for future
	/// custom transport implementations.
	///
	/// - Parameter duration: The duration to suppress all events.
	func updateServerRateLimit(muteFor duration: Duration) {
		lock.withLock { state in
			let now = state.clock.now
			state.serverMuteUntil = now.advanced(by: duration)
			Self.rateLimitLog.warning("Server rate-limit mute enabled for \(String(describing: duration), privacy: .public)")
		}
	}
	
	// MARK: - Helpers
	
	private func pruneGlobalWindow(state: inout State, now: ContinuousClock.Instant) {
		let cutoff = now.advanced(by: .seconds(-3600))
		if state.allowedInstants.isEmpty { return }
		state.allowedInstants.removeAll { $0 < cutoff }
	}
	
	private func logDrop(_ reason: SentryEventDropReason, signatureHex: String, extra: String) {
		// Prefix signature to keep logs short and privacy-safe.
		let prefix = String(signatureHex.prefix(8))
		Self.decisionLog.warning("drop reason=\(reason.rawValue, privacy: .public) sig=\(prefix, privacy: .public) \(extra, privacy: .public)")
	}
}
