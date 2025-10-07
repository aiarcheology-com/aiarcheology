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
    
    static let logDrivers = Logger(subsystem: subsystem, category: "Drivers")
    static let logRendering = Logger(subsystem: subsystem, category: "Rendering")
    static let logConfigration = Logger(subsystem: subsystem, category: "Configuration")
}
