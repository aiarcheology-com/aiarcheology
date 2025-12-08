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
    
    // MARK: - Configuration
    
    private static let queue = DispatchQueue(label: "com.aiarcheology.observability", attributes: .concurrent)
    nonisolated(unsafe) private static var _service: CrashReportingService?
    nonisolated(unsafe) private static var _isStarted = false
    
    // MARK: - Initialization
    
    /// Start the observability system with the specified crash reporting service.
    /// Call this once in your App's init().
    ///
    /// - Parameter service: The crash reporting service implementation to use.
    ///                      Use `NoOpCrashReportingService()` to disable remote reporting.
    static func start(with service: CrashReportingService) {
        queue.async(flags: .barrier) {
            guard !_isStarted else {
                // Use Logger directly here to avoid circular dependency with LoggingPolicy
                Logger.logger.warning("Observability.start() called multiple times - ignoring")
                return
            }
            _service = service
            _isStarted = true
        }
        
        // Start the service outside the barrier to avoid blocking
        service.start()
        Logger.logger.info("Observability started with \(String(describing: type(of: service)))")
    }
    
    /// Check if observability has been started
    static var isStarted: Bool {
        queue.sync { _isStarted }
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
        guard let service = queue.sync(execute: { _service }) else { return }
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
        guard let service = queue.sync(execute: { _service }) else { return }
        service.captureError(message: message, error: error)
    }
    
    /// Capture and send a fault/critical event to the crash reporting service.
    /// ⚠️ This counts toward your event quota - use for critical failures only.
    ///
    /// - Parameter message: Fault description
    static func captureFault(_ message: String) {
        guard let service = queue.sync(execute: { _service }) else { return }
        service.captureFault(message: message)
    }
    
    // MARK: - Custom Context
    
    /// Set a custom attribute for crash reports.
    /// - Parameters:
    ///   - value: Attribute value (must be privacy-safe)
    ///   - key: Attribute key
    static func setCustomValue(_ value: String, forKey key: String) {
        guard let service = queue.sync(execute: { _service }) else { return }
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
