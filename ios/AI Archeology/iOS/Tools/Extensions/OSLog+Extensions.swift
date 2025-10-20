//
//  OSLog+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 07.10.25.
//

import OSLog

extension Logger {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static var subsystem: String { Bundle.main.bundleIdentifier ?? "com.aiarcheology.ios" }
    
    // MARK: - App & Lifecycle
    /// Logs for app-wide events, initialization, and teardown
    static let app = Logger(subsystem: subsystem, category: "App")
    
    /// Logs for app lifecycle events (foreground/background, startup, shutdown)
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    
    // MARK: - Core Features
    /// Logs for AI driver operations (model loading, detection, classification)
    static let drivers = Logger(subsystem: subsystem, category: "Drivers")
    
    /// Logs for rendering operations (snapshots, image processing)
    static let rendering = Logger(subsystem: subsystem, category: "Rendering")
    
    /// Logs for configuration management
    static let configuration = Logger(subsystem: subsystem, category: "Configuration")
    
    // MARK: - Data Layer
    /// Logs for Core Data operations and persistence
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    
    /// Logs for state management operations
    static let state = Logger(subsystem: subsystem, category: "State")
    
    // MARK: - Networking & Downloads
    /// Logs for network operations and model downloads
    static let networking = Logger(subsystem: subsystem, category: "Networking")
    
    // MARK: - UI
    /// Logs for user interface events and interactions
    static let ui = Logger(subsystem: subsystem, category: "UI")
    
    /// Logs for gallery module operations
    static let gallery = Logger(subsystem: subsystem, category: "Gallery")
    
    // MARK: - Deprecated (for backwards compatibility)
    @available(*, deprecated, renamed: "drivers")
    static let logDrivers = Logger(subsystem: subsystem, category: "Drivers")
    
    @available(*, deprecated, renamed: "rendering")
    static let logRendering = Logger(subsystem: subsystem, category: "Rendering")
    
    @available(*, deprecated, renamed: "configuration")
    static let logConfigration = Logger(subsystem: subsystem, category: "Configuration")
}
