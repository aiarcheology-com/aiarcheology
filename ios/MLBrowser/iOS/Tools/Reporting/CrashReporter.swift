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
	case none // No severity; use to suppress breadcrumb recording or indicate absence of a level.
	case debug
	case info
	case warning
	case error
	case fatal // Fatal severity; indicates an unrecoverable error or crash, typically logged as a fault. Use for critical failures beyond `.error`.
}

/// Protocol for crash reporting services integration.
/// Prefer using LoggingPolicy or Observability directly in new code.
protocol CrashReporter: Sendable {
	/// Records a non-fatal error for later analysis
	func recordError(_ error: Error, context: [String: Any]?)
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

		// The crash-reporting service appends error.localizedDescription itself;
		// embedding it here too produced "msg: desc: desc" in captured events.
		let message = "Non-fatal error recorded\(contextString)"

		// Route through Observability for remote reporting
		Observability.captureError(message, error: error)

		// Also log locally (with the description for readability)
		Logger.app.logError("\(message): \(error.localizedDescription)")
	}
}
