//
//  HostPlatform.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 15.10.25.
//

import SwiftUI

enum HostPlatform {
    case iOS
    case iPadOS
    case macViaCatalyst
    case macDesignedForiPad
    
    /// Cached platform value, computed once at startup
    @MainActor
    static let current: HostPlatform = {
        #if targetEnvironment(macCatalyst)
        return .macViaCatalyst
        #else
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                return .macDesignedForiPad
            }
        }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS
        }
        return .iOS
        #elseif os(macOS)
        return .macViaCatalyst // fallback
        #endif
        #endif
    }()
    
    // MARK: - Platform Checks
    
    var isMac: Bool {
        switch self {
        case .macViaCatalyst, .macDesignedForiPad:
            return true
        case .iOS, .iPadOS:
            return false
        }
    }
    
    var isiPad: Bool {
        switch self {
        case .iPadOS:
            return true
        case .iOS, .macViaCatalyst, .macDesignedForiPad:
            return false
        }
    }
    
    var isiPhone: Bool {
        switch self {
        case .iOS:
            return true
        case .iPadOS, .macViaCatalyst, .macDesignedForiPad:
            return false
        }
    }
    
    /// True for iPadOS, macViaCatalyst, and macDesignedForiPad - platforms where swipe gestures conflict with other interactions
    var prefersContextMenuOverSwipe: Bool {
        switch self {
        case .iOS:
            return false
        case .iPadOS, .macViaCatalyst, .macDesignedForiPad:
            return true
        }
    }
}

// MARK: - View Extensions

extension View {
    @MainActor
    @ViewBuilder
    func macOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if HostPlatform.current.isMac {
            transform(self)
        } else {
            self
        }
    }
    
    @MainActor
    @ViewBuilder
    func mobileOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if !HostPlatform.current.isMac {
            transform(self)
        } else {
            self
        }
    }
    
    @MainActor
    @ViewBuilder
    func iPhoneOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if HostPlatform.current.isiPhone {
            transform(self)
        } else {
            self
        }
    }
    
    @MainActor
    @ViewBuilder
    func iPadOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if HostPlatform.current.isiPad {
            transform(self)
        } else {
            self
        }
    }
    
    @MainActor
    @ViewBuilder
    func iPadOrMacOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if HostPlatform.current.isiPad || HostPlatform.current.isMac {
            transform(self)
        } else {
            self
        }
    }
}
