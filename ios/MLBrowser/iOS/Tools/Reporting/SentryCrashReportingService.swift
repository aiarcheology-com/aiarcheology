//
//  SentryCrashReportingService.swift
//  AI Archeology
//
//  Sentry SDK implementation of CrashReportingService.
//  This is the only file that should import Sentry.
//

import Foundation
import Sentry

/// Sentry SDK implementation of the CrashReportingService protocol.
/// Isolates all Sentry-specific code to this single file.
final class SentryCrashReportingService: CrashReportingService {
    
    private let dsn: String
    private let enableProfiling: Bool
    private let tracesSampleRate: Float
    
    /// Initialize the Sentry crash reporting service.
    /// - Parameters:
    ///   - dsn: Sentry DSN (Data Source Name)
    ///   - tracesSampleRate: Performance monitoring sample rate (0.0 to 1.0). Default: 1.0 for dev, reduce in production.
    ///   - enableProfiling: Whether to enable profiling. Default: true for dev, consider disabling in production.
    init(
        dsn: String = "https://84fcc6da78e28f0a8ab379bb6c7e5503@o4510495266570240.ingest.de.sentry.io/4510495268405328",
        tracesSampleRate: Float = 1.0,
        enableProfiling: Bool = true
    ) {
        self.dsn = dsn
        self.tracesSampleRate = tracesSampleRate
        self.enableProfiling = enableProfiling
    }
    
    func start() {
        SentrySDK.start { [self] options in
            options.dsn = dsn
            
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
            
            // Uncomment for additional debugging:
            // options.attachScreenshot = true
            // options.attachViewHierarchy = true
        }
    }
    
    func addBreadcrumb(message: String, level: BreadcrumbLevel, category: String) {
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

// MARK: - BreadcrumbLevel to Sentry Mapping

private extension BreadcrumbLevel {
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
