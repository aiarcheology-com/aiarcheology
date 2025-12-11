//
//  CrashReporter.swift
//  AI Archeology
//
//  Legacy crash reporting abstraction.
//  Delegates to Observability for actual implementation.
//
//  NOTE: New code should use LoggingPolicy or Observability directly.
//  This file exists for backward compatibility with existing call sites.
//

import Foundation
import OSLog

/// Severity levels for breadcrumbs
enum BreadcrumbLevel: String, Sendable {
	case none
	case debug
	case info
	case warning
	case error
	case fatal
}

/// Protocol for crash reporting services integration.
/// Prefer using LoggingPolicy or Observability directly in new code.
protocol CrashReporter: Sendable {
	/// Records a non-fatal error for later analysis
	func recordError(_ error: Error, context: [String: Any]?)
	
	/// Records a custom message as a breadcrumb for debugging
	func recordBreadcrumb(_ message: String, level: BreadcrumbLevel)
	
	/// Sets custom user attributes for crash reports
	func setCustomValue(_ value: String, forKey key: String)
}

/// Default implementation that delegates to Observability.
/// This ensures all crash reporting goes through the same channel.
final class DefaultCrashReporter: CrashReporter, Sendable {
	static let shared = DefaultCrashReporter()
	
	private init() {}
	
	func recordError(_ error: Error, context: [String: Any]?) {
		var contextString = ""
		if let context = context {
			contextString = " context: " + context.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
		}
		
		let message = "Non-fatal error recorded: \(error.localizedDescription)\(contextString)"
		
		// Route through Observability for remote reporting
		Observability.captureError(message, error: error)
		
		// Also log locally
		Logger.app.logError(message)
	}
	
	func recordBreadcrumb(_ message: String, level: BreadcrumbLevel) {
		// Route through Observability
		Observability.recordBreadcrumb(message, level: level, category: "app.breadcrumb")
		
		// Also log locally based on level
		switch level {
		case .none:
			break
		case .debug:
			Logger.app.logDebug("Breadcrumb: \(message)")
		case .info:
			Logger.app.logInfo("Breadcrumb: \(message)")
		case .warning:
			Logger.app.logWarning("Breadcrumb: \(message)")
		case .error:
			Logger.app.logError("Breadcrumb: \(message)")
		case .fatal:
			Logger.app.logFault("Breadcrumb: \(message)")
		}
	}
	
	func setCustomValue(_ value: String, forKey key: String) {
		Observability.setCustomValue(value, forKey: key)
		Logger.app.logDebug("Custom attribute set: \(key)=\(value)")
	}
}
