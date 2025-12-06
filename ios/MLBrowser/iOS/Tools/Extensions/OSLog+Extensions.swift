//
//  OSLog+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 07.10.25.
//

// Swift
import OSLog

extension Logger {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static var subsystem: String { Bundle.main.bundleIdentifier ?? "com.aiarcheology.ios" }
    
    // MARK: - App & Lifecycle
    static let app = Logger(subsystem: subsystem, category: "App")
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    
    // MARK: - Core Features
    static let drivers = Logger(subsystem: subsystem, category: "Drivers")
    static let rendering = Logger(subsystem: subsystem, category: "Rendering")
    static let configuration = Logger(subsystem: subsystem, category: "Configuration")
    
    // MARK: - Data Layer
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let state = Logger(subsystem: subsystem, category: "State")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    
    // MARK: - Networking & Downloads
    static let networking = Logger(subsystem: subsystem, category: "Networking")
    
    // MARK: - UI
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let gallery = Logger(subsystem: subsystem, category: "Gallery")
    
    // MARK: - Deprecated (for backwards compatibility)
    @available(*, deprecated, renamed: "drivers")
    static let logDrivers = Logger(subsystem: subsystem, category: "Drivers")
    @available(*, deprecated, renamed: "rendering")
    static let logRendering = Logger(subsystem: subsystem, category: "Rendering")
    @available(*, deprecated, renamed: "configuration")
    static let logConfigration = Logger(subsystem: subsystem, category: "Configuration")
    
    // MARK: - Timestamp Support
    
    /// Generates a formatted timestamp for log messages (async to honor actor-isolated config)
    private static func timestamp() -> String {
        LoggingConfiguration.timestampPrefix()
    }
    
    // MARK: - Timestamped Logging Methods
    
    func logDebug(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.debug("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.debug("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logInfo(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.info("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.info("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logNotice(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.notice("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.notice("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logWarning(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.warning("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.warning("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logTrace(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.debug("\(ts)[trace] \(evaluatedMessage, privacy: .private)")
        } else {
            self.debug("\(ts)[trace] \(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logError(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.error("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.error("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logFault(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.fault("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.fault("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logCritical(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        let ts = Logger.timestamp()
        if isPrivate {
            self.critical("\(ts)\(evaluatedMessage, privacy: .private)")
        } else {
            self.critical("\(ts)\(evaluatedMessage, privacy: .public)")
        }
    }
}
