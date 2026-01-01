//
//  LocalizationTestHelpers.swift
//  MLBrowser
//
//  Testing utilities for localization validation.
//

import Foundation

// MARK: - Localization Validation

/// Utilities for validating localization in tests.
enum LocalizationValidator {

    /// Checks if a localized string is properly translated (not returning the key).
    ///
    /// - Parameters:
    ///   - localizedString: The localized string to check
    ///   - key: The localization key (for comparison)
    /// - Returns: `true` if the string appears to be translated
    ///
    /// Usage in tests:
    /// ```swift
    /// XCTAssertTrue(
    ///     LocalizationValidator.isTranslated(L10n.History.title, key: "history.title")
    /// )
    /// ```
    static func isTranslated(_ localizedString: String, key: String) -> Bool {
        // A string is considered translated if it doesn't equal its key
        localizedString != key
    }

    /// Checks if a localized string contains expected content.
    ///
    /// Useful for validating format strings with placeholders.
    ///
    /// - Parameters:
    ///   - localizedString: The localized string to check
    ///   - substring: Expected substring
    /// - Returns: `true` if the string contains the substring
    static func contains(_ localizedString: String, substring: String) -> Bool {
        localizedString.contains(substring)
    }

    /// Validates that a localized string is not empty.
    static func isNotEmpty(_ localizedString: String) -> Bool {
        !localizedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Locale Testing

/// Helpers for testing with different locales.
enum LocaleTesting {

    /// Available test locales in the app.
    static var supportedLocales: [Locale] {
        [
            Locale(identifier: "en"),
            Locale(identifier: "de")
        ]
    }

    /// Returns the bundle for a specific locale, if available.
    ///
    /// - Parameter locale: The locale to get the bundle for
    /// - Returns: The localized bundle, or nil if not available
    static func bundle(for locale: Locale) -> Bundle? {
        guard let languageCode = locale.language.languageCode?.identifier,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }

    /// Gets a localized string for a specific locale.
    ///
    /// - Parameters:
    ///   - key: The localization key
    ///   - locale: The locale to use
    ///   - table: The strings table name (default: "Localizable")
    /// - Returns: The localized string, or the key if not found
    static func localizedString(
        forKey key: String,
        locale: Locale,
        table: String = "Localizable"
    ) -> String {
        guard let bundle = bundle(for: locale) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
}

// MARK: - String Catalog Validation

/// Validates String Catalog structure and completeness.
enum StringCatalogValidator {

    /// All known localization keys in the app.
    /// Update this list when adding new keys to the String Catalog.
    static var allKeys: [String] {
        [
            "action.tap_or_click",
            "alert.error.title",
            "alert.history.clear.message",
            "alert.warning.title",
            "common.cancel",
            "common.delete",
            "common.dismiss",
            "common.done",
            "common.edit",
            "common.ok",
            "history.clear.button",
            "history.clear.title",
            "history.section.title",
            "history.title",
            "items.count",
            "models.title",
            "settings.about",
            "settings.introduction",
            "settings.section.annotation",
            "settings.section.debug",
            "settings.section.mlBrowser",
            "settings.section.webContent",
            "settings.sentry.title",
            "settings.title"
        ]
    }

    /// Validates that all keys have translations for a given locale.
    ///
    /// - Parameter locale: The locale to validate
    /// - Returns: Array of keys that are missing translations
    static func missingTranslations(for locale: Locale) -> [String] {
        allKeys.filter { key in
            let translated = LocaleTesting.localizedString(forKey: key, locale: locale)
            return translated == key // Key returned means no translation
        }
    }

    /// Validates that a key exists in the String Catalog.
    ///
    /// - Parameter key: The key to check
    /// - Returns: `true` if the key is known
    static func keyExists(_ key: String) -> Bool {
        allKeys.contains(key)
    }
}
