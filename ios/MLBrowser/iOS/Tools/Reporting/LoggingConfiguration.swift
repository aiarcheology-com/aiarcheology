//
//  LoggingConfiguration.swift
//  AI Archeology
//
//  Configuration for logging behavior including timestamps
//

// Swift
import Foundation

/// Concurrency-safe logging configuration and timestamp formatting (synchronous)
enum LoggingConfiguration {
    enum TimestampFormat: Equatable {
        case iso8601WithMilliseconds
        case custom(String)
    }
    
    // Configuration state protected by a concurrent queue (barrier for writes)
    private static let queue = DispatchQueue(label: "com.aiarcheology.logging.config", attributes: .concurrent)
    nonisolated(unsafe) private static var _timestampsEnabled: Bool = true
    nonisolated(unsafe) private static var _timestampFormat: TimestampFormat = .iso8601WithMilliseconds
    
    // MARK: - Mutations (async barrier writes to avoid blocking callers)
    static func setTimestampsEnabled(_ enabled: Bool) {
        queue.async(flags: .barrier) { _timestampsEnabled = enabled }
    }
    
    static func setTimestampFormat(_ format: TimestampFormat) {
        queue.async(flags: .barrier) { _timestampFormat = format }
    }
    
    // MARK: - Reads (synchronous snapshot)
    static func timestampsEnabled() -> Bool {
        queue.sync { _timestampsEnabled }
    }
    
    static func timestampFormat() -> TimestampFormat {
        queue.sync { _timestampFormat }
    }
    
    // MARK: - Synchronous timestamp prefix
    static func timestampPrefix(now: Date = Date()) -> String {
        let (enabled, format) = queue.sync { (_timestampsEnabled, _timestampFormat) }
        guard enabled else { return "" }
        let formatter = format.threadLocalFormatter()
        return "\(formatter.string(from: now)) "
    }
    
    // MARK: - File:Line prefix
    static func fileLinePrefix(file: String, line: UInt) -> String {
        let fileName = (file as NSString).lastPathComponent
        return "\(fileName):\(line) "
    }
    
    // MARK: - Combined prefix (timestamp + file:line)
    static func logPrefix(file: String, line: UInt, now: Date = Date()) -> String {
        let ts = timestampPrefix(now: now)
        let fl = fileLinePrefix(file: file, line: line)
        return "\(ts)\(fl)"
    }
}

private extension LoggingConfiguration.TimestampFormat {
    // Thread-local formatter per pattern to avoid cross-thread `DateFormatter` access
    func threadLocalFormatter() -> DateFormatter {
        let key: String
        switch self {
        case .iso8601WithMilliseconds:
            key = "com.aiarcheology.logging.df.iso8601ms"
        case .custom(let pattern):
            key = "com.aiarcheology.logging.df.custom.\(pattern)"
        }
        
        let dict = Thread.current.threadDictionary
        if let cached = dict[key] as? DateFormatter { return cached }
        
        let formatter = DateFormatter()
        switch self {
        case .iso8601WithMilliseconds:
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        case .custom(let pattern):
            formatter.dateFormat = pattern
        }
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        dict[key] = formatter
        return formatter
    }
}
