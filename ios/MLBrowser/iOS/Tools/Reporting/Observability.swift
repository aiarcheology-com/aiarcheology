//
//  Observability.swift
//  AI Archeology
//
//  Single entry point for crash reporting and remote observability.
//  MLBrowser.swift should only interact with Observability, never directly with Sentry.
//

import Foundation
import OSLog

// MARK: - Crash Reporting Service Protocol

/// Protocol for crash reporting SDK implementations.
/// Implement this to integrate different crash reporting services (Sentry, Crashlytics, etc.)
protocol CrashReportingService: Sendable {
	/// Initialize the crash reporting SDK. Called once at app launch.
	func start()
	
	/// Record a breadcrumb for debugging context (typically free, attached to crash reports)
	/// - Parameters:
	///   - message: The breadcrumb message
	///   - level: Severity level
	///   - category: Category for filtering (e.g., "app.log", "navigation", "network")
	func addBreadcrumb(message: String, level: BreadcrumbLevel, category: String)
	
	/// Capture and send an error event (typically counts toward quota)
	/// - Parameters:
	///   - message: Error description
	///   - error: Optional underlying error
	func captureError(message: String, error: Error?)
	
	/// Capture and send a fault/critical event (typically counts toward quota)
	/// - Parameter message: Fault description
	func captureFault(message: String)
	
	/// Set custom user context
	/// - Parameters:
	///   - key: Attribute key
	///   - value: Attribute value (must be privacy-safe)
	func setCustomValue(_ value: String, forKey key: String)
}

// MARK: - Observability

/// Central observability facade for the application.
/// Provides a clean abstraction over crash reporting SDKs.
///
/// Usage:
/// ```swift
/// // In App init:
/// Observability.start(with: SentryCrashReportingService())
///
/// // Throughout the app (via LoggingPolicy):
/// LoggingPolicy.info("User tapped button", logger: .ui)
/// LoggingPolicy.error("Network failed", error: networkError, logger: .networking)
/// ```
enum Observability {
	
	// MARK: - Thread-Safe State (Write-Once Pattern)
	
	/// The service reference. Write-once during start(), then read-only forever.
	/// Uses nonisolated(unsafe) with careful ordering: _service is set BEFORE _isStarted.
	/// This ensures any thread that sees _isStarted==true will also see _service set.
	private nonisolated(unsafe) static var _service: CrashReportingService?
	
	/// Lock protects ONLY the initialization path to prevent double-start.
	/// After initialization, _service can be read lock-free (it never changes).
	private static let initLock = OSAllocatedUnfairLock<Void>(initialState: ())
	private nonisolated(unsafe) static var _isStarted = false
	
	// MARK: - Initialization
	
	/// Start the observability system with the specified crash reporting service.
	/// Call this once in your App's init().
	///
	/// - Parameter service: The crash reporting service implementation to use.
	///                      Use `NoOpCrashReportingService()` to disable remote reporting.
	static func start(with service: CrashReportingService) {
		// Lock ensures only one thread can initialize
		let didInitialize = initLock.withLock { () -> Bool in
			guard !_isStarted else {
				Logger.logger.warning("Observability.start() called multiple times - ignoring")
				return false
			}
			// Order matters: set _service BEFORE _isStarted
			// Lock release provides memory barrier ensuring visibility
			_service = service
			_isStarted = true
			return true
		}
		
		guard didInitialize else { return }
		
		service.start()
		Logger.logger.info("Observability started with \(String(describing: type(of: service)))")
	}
	
	/// Check if observability has been started.
	/// Lock-free read - safe because _isStarted transitions false→true exactly once.
	static var isStarted: Bool {
		_isStarted
	}
	
	// MARK: - Breadcrumbs (FREE - attached to crash reports)
	
	/// Record a breadcrumb for debugging context.
	/// Breadcrumbs are FREE - they're only uploaded when attached to a crash/error event.
	///
	/// - Parameters:
	///   - message: The breadcrumb message
	///   - level: Severity level (default: .info)
	///   - category: Category for filtering (default: "app.log")
	static func recordBreadcrumb(
		_ message: String,
		level: BreadcrumbLevel = .info,
		category: String = "app.log"
	) {
		// Lock-free read: safe because _service is write-once and set before isStarted
		guard let service = _service else { return }
		service.addBreadcrumb(message: message, level: level, category: category)
	}
	
	// MARK: - Error Capture (QUOTA - uses event quota)
	
	/// Capture and send an error event to the crash reporting service.
	/// ⚠️ This counts toward your event quota - use sparingly for significant errors.
	///
	/// - Parameters:
	///   - message: Error description
	///   - error: Optional underlying error
	static func captureError(_ message: String, error: Error? = nil) {
		guard let service = _service else { return }
		service.captureError(message: message, error: error)
	}
	
	/// Capture and send a fault/critical event to the crash reporting service.
	/// ⚠️ This counts toward your event quota - use for critical failures only.
	///
	/// - Parameter message: Fault description
	static func captureFault(_ message: String) {
		guard let service = _service else { return }
		service.captureFault(message: message)
	}
	
	// MARK: - Custom Context
	
	/// Set a custom attribute for crash reports.
	/// - Parameters:
	///   - value: Attribute value (must be privacy-safe)
	///   - key: Attribute key
	static func setCustomValue(_ value: String, forKey key: String) {
		guard let service = _service else { return }
		service.setCustomValue(value, forKey: key)
	}
}

// MARK: - NoOp Implementation

/// No-operation implementation for testing or when crash reporting is disabled.
final class NoOpCrashReportingService: CrashReportingService {
	func start() {
		Logger.logger.info("NoOpCrashReportingService: start() called")
	}
	
	func addBreadcrumb(message: String, level: BreadcrumbLevel, category: String) {
		// No-op: breadcrumbs go nowhere
	}
	
	func captureError(message: String, error: Error?) {
		// No-op: errors not sent
	}
	
	func captureFault(message: String) {
		// No-op: faults not sent
	}
	
	func setCustomValue(_ value: String, forKey key: String) {
		// No-op
	}
}

// MARK: - Test Triggers

extension Observability {
	
	/// Runs all enabled Sentry test modes based on environment variables.
	/// Call this after `Observability.start()` in your App's init.
	///
	/// Supported environment variables:
	/// - `SENTRY_TEST_ERROR`: Triggers a test error via `LoggingPolicy.error`
	/// - `SENTRY_TEST_CRASH`: Triggers an app crash after 1 second delay
	/// - `SENTRY_THROTTLE_SMOKE_TEST`: Runs throttle/dedup smoke tests (`duplicate` or `global`)
	static func runTestTriggersIfEnabled() {
		runSentryTestErrorIfEnabled()
		runSentryTestCrashIfEnabled()
		runSentryThrottleSmokeTestIfEnabled()
	}
	
	/// Triggers a test error when `SENTRY_TEST_ERROR` env var is set.
	/// Each invocation generates a unique error to prevent Sentry from grouping them.
	private static func runSentryTestErrorIfEnabled() {
		guard AppEnvironment.shouldTriggerTestError else { return }
		
		let uniqueId = UUID().uuidString.prefix(8)
		let timestamp = ISO8601DateFormatter().string(from: Date())
		
		Logger.logger.warning("[SentryTest] SENTRY_TEST_ERROR is set - triggering test error [\(uniqueId)]")
		LoggingPolicy.error(
			"Sentry test error [\(uniqueId)] triggered at \(timestamp)",
			error: NSError(domain: "SentryTestError.\(uniqueId)", code: Int.random(in: 1...9999), userInfo: [
				NSLocalizedDescriptionKey: "Test error [\(uniqueId)] to verify Sentry integration"
			]),
			logger: .lifecycle
		)
		Logger.logger.info("[SentryTest] Test error [\(uniqueId)] sent to Sentry")
	}
	
	/// Triggers an app crash when `SENTRY_TEST_CRASH` env var is set.
	/// Each invocation uses a different crash method to create unique stack traces.
	private static func runSentryTestCrashIfEnabled() {
		guard AppEnvironment.shouldTriggerTestCrash else { return }
		
		let uniqueId = UUID().uuidString.prefix(8)
		let crashMethod = Int.random(in: 0...2)
		
		Logger.logger.warning("[SentryTest] SENTRY_TEST_CRASH is set - triggering test crash [\(uniqueId)] method \(crashMethod) in 1 second")
		LoggingPolicy.fault("About to trigger test crash [\(uniqueId)] via SENTRY_TEST_CRASH (method \(crashMethod))", logger: .lifecycle)
		
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
			Logger.logger.fault("[SentryTest] Triggering crash [\(uniqueId)] now using method \(crashMethod)")
			
			switch crashMethod {
			case 0:
				fatalError("Sentry test crash [\(uniqueId)]")
			case 1:
				preconditionFailure("Sentry test crash [\(uniqueId)]")
			default:
				// Explicit crash to create a different crash signature
				fatalError("Sentry test crash [\(uniqueId)] via method 2 (alternative fatal error)")
			}
		}
	}
	
	/// Runs throttle/dedup smoke tests when `SENTRY_THROTTLE_SMOKE_TEST` env var is set.
	/// - `duplicate`: emits many identical errors (should mostly be deduped)
	/// - `global`: emits many unique errors (should hit global cap)
	private static func runSentryThrottleSmokeTestIfEnabled() {
		guard let mode = AppEnvironment.sentryThrottleSmokeTestMode, !mode.isEmpty else { return }
		
		Logger.logger.info("[SentryThrottle] Starting smoke test with mode: \(mode, privacy: .public)")
		
		Task.detached(priority: .background) {
			switch mode {
			case "duplicate":
				for _ in 0..<120 {
					LoggingPolicy.error(
						"Sentry throttle smoke test (duplicate)",
						error: NSError(domain: "SentryThrottleSmokeTest", code: 1)
					)
				}
				Logger.logger.info("[SentryThrottle] Smoke test 'duplicate' completed: sent 120 duplicate events")
				
			case "global":
				for i in 0..<200 {
					LoggingPolicy.error(
						"Sentry throttle smoke test (global)",
						error: NSError(domain: "SentryThrottleSmokeTest", code: i)
					)
				}
				Logger.logger.info("[SentryThrottle] Smoke test 'global' completed: sent 200 unique events")
				
			default:
				Logger.logger.warning("Unknown SENTRY_THROTTLE_SMOKE_TEST value: \(mode, privacy: .public)")
			}
		}
	}
}
