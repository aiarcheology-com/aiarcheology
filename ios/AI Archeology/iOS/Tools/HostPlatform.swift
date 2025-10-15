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
    
    static var current: HostPlatform {
    #if targetEnvironment(macCatalyst)
        return .macViaCatalyst
    #else
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                return .macDesignedForiPad
            }
        }
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macViaCatalyst // fallback
        #endif
    #endif
    }
    
    var isMac: Bool {
        switch self {
        case .macViaCatalyst, .macDesignedForiPad:
            return true
        default:
            return false
        }
    }
}

extension View {
    @ViewBuilder
    func macOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if HostPlatform.current.isMac {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func mobileOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
        if !HostPlatform.current.isMac {
            transform(self)
        } else {
            self
        }
    }
}
