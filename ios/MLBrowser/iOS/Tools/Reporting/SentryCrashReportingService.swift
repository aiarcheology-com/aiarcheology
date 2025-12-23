//
//  SentryCrashReportingService.swift
//  AI Archeology
//
//  Sentry SDK implementation of CrashReportingService.
//  This is the only file that should import Sentry.
//

import Foundation
import Sentry
import OSLog

/// Sentry SDK implementation of the CrashReportingService protocol.
/// Isolates all Sentry-specific code to this single file.
final class SentryCrashReportingService: CrashReportingService {
	
	private let dsn: String?
	private let enableProfiling: Bool
	private let tracesSampleRate: Float
	private let throttleConfig: SentryThrottleConfig
	private let eventGuard: SentryEventGuard
	private let breadcrumbGuard: SentryBreadcrumbGuard
	
	/// Initialize the Sentry crash reporting service.
	/// - Parameters:
	///   - dsn: Sentry DSN (Data Source Name). If nil, reads from Info.plist "SentryDSN" key.
	///   - tracesSampleRate: Performance monitoring sample rate (0.0 to 1.0). Default: 1.0 for dev, reduce in production.
	///   - enableProfiling: Whether to enable profiling. Default: true for dev, consider disabling in production.
	init(
		dsn: String? = nil,
		tracesSampleRate: Float = 1.0,
		enableProfiling: Bool = false,
		throttleConfig: SentryThrottleConfig = .default
	) {
		self.dsn = dsn ?? Self.dsnFromInfoPlist()
		self.tracesSampleRate = tracesSampleRate
		self.enableProfiling = enableProfiling
		self.throttleConfig = throttleConfig
		self.eventGuard = SentryEventGuard(config: throttleConfig)
		self.breadcrumbGuard = SentryBreadcrumbGuard(
			perSignatureCooldown: throttleConfig.perSignatureCooldown,
			perSignatureBurst: throttleConfig.perSignatureBurst,
			sampleEveryNthDuplicate: throttleConfig.sampleEveryNthDuplicate,
			signatureCacheLimit: throttleConfig.signatureCacheLimit
		)
	}
	
	/// Reads the Sentry DSN from Info.plist.
	/// The DSN is injected via xcconfig → Info.plist build settings.
	private static func dsnFromInfoPlist() -> String? {
		Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String
	}
	
	func start() {
		
		guard let dsn = dsn, !dsn.isEmpty else {
			// DSN not configured - Sentry will be disabled
			// This can happen in development if secrets aren't set up
#if DEBUG
			Logger.logger.debug("Sentry DSN not configured. Run: swift run ProjectTool secrets generate")
#endif
			return
		}
		
		let tracesSampleRate = self.tracesSampleRate
		let enableProfiling = self.enableProfiling
		
		// Expose guard stats for DEBUG UI (if Sentry is enabled for this build).
		SentryThrottleDiagnostics.install { [eventGuard] in
			SentryThrottleDiagnosticsSnapshot(
				config: eventGuard.configSnapshot(),
				stats: eventGuard.statsSnapshot()
			)
		}
		
		SentrySDK.start { options in
			options.dsn = dsn
			
			// Enable debug logging in DEBUG builds
#if DEBUG && false
			options.debug = true
			Logger.logger.debug("[Sentry] Initializing with DSN: \(dsn.prefix(50))...")
#endif
			
			// Adds IP for users.
			// For more information: https://docs.sentry.io/platforms/apple/data-management/data-collected/
			options.sendDefaultPii = true
			
			// Performance monitoring sample rate
			options.tracesSampleRate = NSNumber(value: tracesSampleRate)
			
			// Configure profiling if enabled
			// https://docs.sentry.io/platforms/apple/profiling/
			if enableProfiling {
				options.configureProfiling = {
					$0.sessionSampleRate = 1.0 // Adjust in production
					$0.lifecycle = .trace
				}
			}
			
			// Enable experimental logging features
			options.experimental.enableLogs = true
			
			// Client-side event throttling + deduplication (iOS 17+ target).
			// Note: Native crash reports bypass `beforeSend` and are intentionally not throttled.
			// Note: Sentry Cocoa transport honors `Retry-After` and `X-Sentry-Rate-Limits` internally.
			let throttleConfig = self.throttleConfig
			let eventGuard = self.eventGuard
			options.beforeSend = { event in
				guard throttleConfig.isEnabled else { return event }
				
				guard let input = Self.signatureInput(from: event),
					  let signatureHex = SentryEventSignatureBuilder.signatureHex(from: input)
				else {
					// If we can't build a stable signature, don't risk dropping.
					return event
				}
				
				let decision = eventGuard.decide(signatureHex: signatureHex)
				guard decision.isAllowed else { return nil }
				
				if throttleConfig.enableSuppressedCountBreadcrumb,
				   decision.suppressedDuplicatesToReport > 0
				{
					let count = decision.suppressedDuplicatesToReport
					let prefix = String(signatureHex.prefix(8))
					
					// Attach minimal context to the event itself.
					var extra = event.extra ?? [:]
					extra["sentry_throttle.suppressed_duplicates"] = count
					extra["sentry_throttle.signature_prefix"] = prefix
					event.extra = extra
					
					let crumb = Breadcrumb()
					crumb.level = .info
					crumb.category = "sentry.throttle"
					crumb.message = "Suppressed \(count) duplicate events (sig=\(prefix))"
					event.breadcrumbs = (event.breadcrumbs ?? []) + [crumb]
				}
				
				return event
			}
			
			// Uncomment for additional debugging:
			// options.attachScreenshot = true
			// options.attachViewHierarchy = true
		}
	}
	
	// MARK: - Signature Extraction (Sentry -> SDK-agnostic input)
	
	private static func signatureInput(from event: Event) -> SentryEventSignatureInput? {
		// Prefer parsing serialized payload to avoid depending on SDK model accessors.
		let payload = event.serialize()
		
		let message: String? = {
			if let s = payload["message"] as? String { return s }
			if let m = payload["message"] as? [String: Any] {
				return (m["formatted"] as? String) ?? (m["message"] as? String)
			}
			return nil
		}()
		
		let (errorType, frames) = extractTypeAndFrames(payload: payload)
		
		// Use top 5 frames, symbol names only.
		let topFrames = Array(frames.suffix(5))
		return SentryEventSignatureInput(errorType: errorType, message: message, topFrames: topFrames)
	}
	
	private static func extractTypeAndFrames(payload: [String: Any]) -> (String?, [String]) {
		// 1) Exception stacktrace
		if let exception = payload["exception"] as? [String: Any],
		   let values = exception["values"] as? [[String: Any]],
		   let first = values.first
		{
			let type = (first["type"] as? String) ?? (first["value"] as? String)
			let frames = extractFrames(from: first["stacktrace"])
			if !frames.isEmpty || type != nil {
				return (type, frames)
			}
		}
		
		// 2) Thread stacktrace
		if let threads = payload["threads"] as? [String: Any],
		   let values = threads["values"] as? [[String: Any]],
		   let first = values.first
		{
			let frames = extractFrames(from: first["stacktrace"])
			if !frames.isEmpty {
				return (nil, frames)
			}
		}
		
		// 3) Top-level stacktrace (fallback)
		let frames = extractFrames(from: payload["stacktrace"])
		return (nil, frames)
	}
	
	private static func extractFrames(from stacktraceAny: Any?) -> [String] {
		guard let stacktrace = stacktraceAny as? [String: Any],
			  let frames = stacktrace["frames"] as? [[String: Any]]
		else { return [] }
		
		// Sentry frames are often ordered oldest -> newest. Keep the most recent frames.
		return frames.compactMap { frame in
			(frame["function"] as? String) ?? (frame["symbol"] as? String)
		}
	}
	
	func addBreadcrumb(message: String, level: BreadcrumbLevel, category: String) {
		// Breadcrumbs do not cost quota, but in an error loop they can flood the breadcrumb ring buffer
		// and then get attached to the next allowed event. Throttle only error-ish breadcrumbs.
		if throttleConfig.isEnabled,
		   (level == .error || level == .fatal),
		   let signature = SentryEventSignatureBuilder.signatureHex(
			from: SentryEventSignatureInput(errorType: nil, message: message, topFrames: [])
		   ),
		   !breadcrumbGuard.shouldAllow(signatureHex: signature)
		{
			return
		}
		
		let crumb = Breadcrumb()
		crumb.level = level.toSentryLevel()
		crumb.category = category
		crumb.message = message
		SentrySDK.addBreadcrumb(crumb)
	}
	
	func captureError(message: String, error: Error?) {
		let finalMessage: String
		if let error = error {
			finalMessage = "\(message): \(error.localizedDescription)"
		} else {
			finalMessage = message
		}
		SentrySDK.capture(message: finalMessage)
	}
	
	func captureFault(message: String) {
		// Faults are critical - capture with error level
		SentrySDK.capture(message: "[FAULT] \(message)")
	}
	
	func setCustomValue(_ value: String, forKey key: String) {
		SentrySDK.configureScope { scope in
			scope.setExtra(value: value, key: key)
		}
	}
}

// MARK: - Breadcrumb Guard (bounded, synchronous)

/// Lightweight guard to reduce repeated error breadcrumbs during event bursts.
///
/// This is intentionally separate from `SentryEventGuard` to avoid mixing counters
/// and to keep breadcrumb control independent of event quota logic.
private final class SentryBreadcrumbGuard: @unchecked Sendable {
	
	private struct Entry {
		var windowStart: ContinuousClock.Instant
		var sentInWindow: Int
		var duplicateCounter: Int
	}
	
	private struct State: @unchecked Sendable {
		var clock: ContinuousClock = ContinuousClock()
		var perSignatureCooldown: Duration
		var perSignatureBurst: Int
		var sampleEveryNthDuplicate: Int
		var lru: LRU
	}
	
	private struct LRU {
		final class Node {
			let key: String
			var value: Entry
			var prev: Node?
			var next: Node?
			
			init(key: String, value: Entry) {
				self.key = key
				self.value = value
			}
		}
		
		var capacity: Int
		private(set) var map: [String: Node] = [:]
		private(set) var head: Node?
		private(set) var tail: Node?
		
		init(capacity: Int) {
			self.capacity = max(1, capacity)
		}
		
		mutating func withValue(forKey key: String, createIfMissing: () -> Entry, _ body: (inout Entry) -> Void) {
			if let node = map[key] {
				touch(node)
				body(&node.value)
				return
			}
			
			let node = Node(key: key, value: createIfMissing())
			insertAtHead(node)
			map[key] = node
			evictIfNeeded()
			body(&node.value)
		}
		
		private mutating func touch(_ node: Node) {
			guard head !== node else { return }
			let prev = node.prev
			let next = node.next
			prev?.next = next
			next?.prev = prev
			if tail === node { tail = prev }
			
			node.prev = nil
			node.next = head
			head?.prev = node
			head = node
			if tail == nil { tail = node }
		}
		
		private mutating func insertAtHead(_ node: Node) {
			node.prev = nil
			node.next = head
			head?.prev = node
			head = node
			if tail == nil { tail = node }
		}
		
		private mutating func evictIfNeeded() {
			while map.count > capacity, let tail {
				map[tail.key] = nil
				let prev = tail.prev
				prev?.next = nil
				self.tail = prev
				if self.tail == nil { head = nil }
			}
		}
	}
	
	private let lock: OSAllocatedUnfairLock<State>
	
	init(
		perSignatureCooldown: Duration,
		perSignatureBurst: Int,
		sampleEveryNthDuplicate: Int,
		signatureCacheLimit: Int
	) {
		self.lock = OSAllocatedUnfairLock(
			initialState: State(
				perSignatureCooldown: perSignatureCooldown,
				perSignatureBurst: perSignatureBurst,
				sampleEveryNthDuplicate: sampleEveryNthDuplicate,
				lru: LRU(capacity: signatureCacheLimit)
			)
		)
	}
	
	func shouldAllow(signatureHex: String) -> Bool {
		lock.withLock { state in
			let now = state.clock.now
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
}

// MARK: - BreadcrumbLevel to Sentry Mapping

extension BreadcrumbLevel {
	func toSentryLevel() -> SentryLevel {
		switch self {
		case .none:
			return .none
		case .debug:
			return .debug
		case .info:
			return .info
		case .warning:
			return .warning
		case .error:
			return .error
		case .fatal:
			return .fatal
		}
	}
}
