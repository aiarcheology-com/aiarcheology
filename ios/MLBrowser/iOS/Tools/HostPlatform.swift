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
    
    /// Whether StoreKit's in-app "Manage Subscription" sheet — `View.manageSubscriptionsSheet`,
    /// i.e. `AppStore.showManageSubscriptions(in:)` — can actually be presented on this host.
    ///
    /// False on iOS-on-Mac. `storekitagent` answers the app's request with
    /// *"manageSubscriptionsEngagementRequest(with:reply:) is unsupported on the current
    /// platform"* (`SKInternalErrorDomain` 9 → `StoreKitError.unknown`), and the SwiftUI modifier
    /// has no error channel, so the tap produces nothing whatsoever: no sheet, no message.
    /// Callers must send the user to `URL.appleManageSubscriptions` instead.
    ///
    /// Catalyst stays `true`: StoreKit declares the sheet available on macCatalyst, and this
    /// target does not build Catalyst, so it must not inherit a workaround verified elsewhere.
    var supportsManageSubscriptionsSheet: Bool {
        switch self {
        case .iOS, .iPadOS, .macViaCatalyst:
            return true
        case .macDesignedForiPad:
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
