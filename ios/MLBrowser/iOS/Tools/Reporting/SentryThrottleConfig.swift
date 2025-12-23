//
//  SentryThrottleConfig.swift
//  AI Archeology
//
//  Compile-time configuration for client-side Sentry event throttling/deduplication.
//  Hot reload not required (v1).
//

import Foundation

/// Policy knobs for Sentry event guardrails.
///
/// Note: This only affects events processed by Sentry's `beforeSend` hook.
/// Native crash reports (SentryCrashIntegration) are expected to bypass it.
struct SentryThrottleConfig: Sendable {
	/// Master switch. If disabled, all events pass through unmodified.
	var isEnabled: Bool = true
	
	/// Duplicate suppression window per signature.
	var perSignatureCooldown: Duration = .seconds(300)
	
	/// Initial burst allowance per signature (captures first occurrences for context).
	var perSignatureBurst: Int = 2
	
	/// Global cap across all signatures.
	var globalCapPerHour: Int = 50
	
	/// Hard stop per app launch.
	var sessionCap: Int = 100
	
	/// Bounded LRU capacity for signature state.
	var signatureCacheLimit: Int = 200
	
	/// Allow every Nth duplicate even within cooldown (0/1 disables sampling).
	var sampleEveryNthDuplicate: Int = 10
	
	/// If true, attach suppressed count to the next allowed event as a breadcrumb.
	var enableSuppressedCountBreadcrumb: Bool = true
	
	static let `default` = SentryThrottleConfig()
}


