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
        
    // MARK: - Logging Methods
    //
    // These methods receive pre-formatted messages from LoggingPolicy
    // (which adds timestamp + file:line prefix).
    
    func logDebug(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.debug("\(evaluatedMessage, privacy: .private)")
        } else {
            self.debug("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logInfo(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.info("\(evaluatedMessage, privacy: .private)")
        } else {
            self.info("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logNotice(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.notice("\(evaluatedMessage, privacy: .private)")
        } else {
            self.notice("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logWarning(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.warning("\(evaluatedMessage, privacy: .private)")
        } else {
            self.warning("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logTrace(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.debug("[trace] \(evaluatedMessage, privacy: .private)")
        } else {
            self.debug("[trace] \(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logError(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.error("\(evaluatedMessage, privacy: .private)")
        } else {
            self.error("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logFault(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.fault("\(evaluatedMessage, privacy: .private)")
        } else {
            self.fault("\(evaluatedMessage, privacy: .public)")
        }
    }
    
    func logCritical(_ message: @autoclosure () -> String, isPrivate: Bool = false) {
        let evaluatedMessage = message()
        if isPrivate {
            self.critical("\(evaluatedMessage, privacy: .private)")
        } else {
            self.critical("\(evaluatedMessage, privacy: .public)")
        }
    }
}
