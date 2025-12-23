//
//  SentryBreadcrumbGuard.swift
//  AI Archeology
//
//  Lightweight guard to reduce repeated error breadcrumbs during event bursts.
//  Intentionally separate from SentryEventGuard to avoid mixing counters.
//

import Foundation
import OSLog

/// Lightweight guard to reduce repeated error breadcrumbs during event bursts.
///
/// This is intentionally separate from `SentryEventGuard` to avoid mixing counters
/// and to keep breadcrumb control independent of event quota logic.
final class SentryBreadcrumbGuard: @unchecked Sendable {
	
	private struct Entry {
		var windowStart: ContinuousClock.Instant
		var sentInWindow: Int
		var duplicateCounter: Int
	}
	
	private struct State: @unchecked Sendable {
		var clock: ContinuousClock
		var perSignatureCooldown: Duration
		var perSignatureBurst: Int
		var sampleEveryNthDuplicate: Int
		var lru: LRUCache<String, Entry>
	}
	
	private let lock: OSAllocatedUnfairLock<State>
	
	init(
		perSignatureCooldown: Duration,
		perSignatureBurst: Int,
		sampleEveryNthDuplicate: Int,
		signatureCacheLimit: Int,
		clock: ContinuousClock = ContinuousClock()
	) {
		self.lock = OSAllocatedUnfairLock(
			initialState: State(
				clock: clock,
				perSignatureCooldown: perSignatureCooldown,
				perSignatureBurst: perSignatureBurst,
				sampleEveryNthDuplicate: sampleEveryNthDuplicate,
				lru: LRUCache(capacity: signatureCacheLimit)
			)
		)
	}
	
	func shouldAllow(signatureHex: String) -> Bool {
		lock.withLock { state in
			shouldAllowLocked(signatureHex: signatureHex, now: state.clock.now, state: &state)
		}
	}
	
	/// Test-only entry point: allows deterministic time without sleeping.
	///
	/// Do not use from production code; prefer `shouldAllow(signatureHex:)`.
	func shouldAllow(signatureHex: String, now: ContinuousClock.Instant) -> Bool {
		lock.withLock { state in
			shouldAllowLocked(signatureHex: signatureHex, now: now, state: &state)
		}
	}
	
	private func shouldAllowLocked(signatureHex: String, now: ContinuousClock.Instant, state: inout State) -> Bool {
		let cooldown = state.perSignatureCooldown
		let burst = max(1, state.perSignatureBurst)
		let sampleN = state.sampleEveryNthDuplicate
		
		var allowed = false
		state.lru.withValue(forKey: signatureHex, createIfMissing: {
			Entry(windowStart: now, sentInWindow: 0, duplicateCounter: 0)
		}) { entry in
			if entry.windowStart.duration(to: now) >= cooldown {
				entry.windowStart = now
				entry.sentInWindow = 0
				entry.duplicateCounter = 0
			}
			
			entry.duplicateCounter += 1
			
			if entry.sentInWindow < burst {
				allowed = true
			} else if sampleN >= 2, entry.duplicateCounter % sampleN == 0 {
				allowed = true
			} else {
				allowed = false
			}
			
			if allowed { entry.sentInWindow += 1 }
		}
		
		return allowed
	}
}
