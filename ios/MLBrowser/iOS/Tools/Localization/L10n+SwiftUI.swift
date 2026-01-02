//
//  L10n+SwiftUI.swift
//  MLBrowser
//
//  Provides SwiftUI integration for type-safe localized strings.
//

import SwiftUI

// MARK: - Text Initialization

extension Text {
    /// Creates a Text view from a localized string.
    ///
    /// Usage:
    /// ```swift
    /// Text(L10n.History.title)
    /// // or with the convenience initializer:
    /// Text(localized: L10n.History.title)
    /// ```
    init(localized string: String) {
        self.init(verbatim: string)
    }
}

// MARK: - LocalizedStringKey Conversion

extension L10n {
    /// Converts a localized string to LocalizedStringKey for SwiftUI views
    /// that require it (like some modifiers).
    ///
    /// Note: Since L10n strings are already localized, we use verbatim
    /// to prevent double-localization.
    static func key(_ string: String) -> LocalizedStringKey {
        LocalizedStringKey(stringLiteral: string)
    }
}

// MARK: - Alert Helpers

/// Creates a SwiftUI Alert with localized strings.
///
/// Usage:
/// ```swift
/// .alert(isPresented: $showAlert) {
///     localizedAlert(
///         title: L10n.Alert.Warning.title,
///         message: L10n.Alert.History.Clear.message,
///         primaryButton: .destructive(Text(L10n.Common.delete)) { ... },
///         secondaryButton: .cancel()
///     )
/// }
/// ```
func localizedAlert(
    title: String,
    message: String? = nil,
    primaryButton: SwiftUI.Alert.Button,
    secondaryButton: SwiftUI.Alert.Button? = nil
) -> SwiftUI.Alert {
    if let secondaryButton = secondaryButton {
        return SwiftUI.Alert(
            title: Text(verbatim: title),
            message: message.map { Text(verbatim: $0) },
            primaryButton: primaryButton,
            secondaryButton: secondaryButton
        )
    } else {
        return SwiftUI.Alert(
            title: Text(verbatim: title),
            message: message.map { Text(verbatim: $0) },
            dismissButton: primaryButton
        )
    }
}

// MARK: - Button Helpers

extension Button where Label == Text {
    /// Creates a button with a localized label.
    ///
    /// Usage:
    /// ```swift
    /// Button(localized: L10n.Common.done) {
    ///     dismiss()
    /// }
    /// ```
    init(localized title: String, action: @escaping () -> Void) {
        self.init(action: action) {
            Text(verbatim: title)
        }
    }
}

// MARK: - Navigation Title

extension View {
    /// Sets the navigation title using a localized string.
    ///
    /// Usage:
    /// ```swift
    /// .navigationTitle(localized: L10n.History.title)
    /// ```
    func navigationTitle(localized title: String) -> some View {
        self.navigationTitle(title)
    }
}
