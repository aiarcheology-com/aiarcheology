//
//  DrawerManager.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import Observation

/// Observable state manager for the drawer/side menu.
///
/// Inject this into the environment at the app root level to allow
/// any child view to open/close the drawer.
///
/// Usage:
/// ```swift
/// @Environment(DrawerManager.self) private var drawer
/// Button("Open") { drawer.open() }
/// ```
@Observable
@MainActor
final class DrawerManager {
    /// Whether the drawer is currently open
    var isOpen: Bool = false
    
    /// The animation used for drawer transitions
    private let animation: Animation = .snappy(duration: 0.3)
    
    /// Opens the drawer with animation
    func open() {
        withAnimation(animation) {
            isOpen = true
        }
    }
    
    /// Closes the drawer with animation
    func close() {
        withAnimation(animation) {
            isOpen = false
        }
    }
    
    /// Toggles the drawer state with animation
    func toggle() {
        withAnimation(animation) {
            isOpen.toggle()
        }
    }
}
