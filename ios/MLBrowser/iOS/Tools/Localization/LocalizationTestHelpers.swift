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
            // About
            "about.copyright",
            "about.privacyNotAvailable",
            "about.privacyPolicy",
            "about.section.application",
            "about.section.contact",
            "about.section.legal",
            "about.version",
            // Action
            "action.tap_or_click",
            // Adjustment
            "adjustment.brightness",
            "adjustment.contentPreview",
            "adjustment.contrast",
            "adjustment.dismissHint",
            "adjustment.saturation",
            "adjustment.title",
            // Alert
            "alert.error.title",
            "alert.history.clear.message",
            "alert.history.full.message",
            "alert.restore.message",
            "alert.warning.title",
            // Clipboard
            "clipboard.copied",
            // Common
            "common.cancel",
            "common.clear",
            "common.delete",
            "common.dismiss",
            "common.done",
            "common.edit",
            "common.import",
            "common.ok",
            "common.reset",
            // Configuration
            "configuration.author",
            "configuration.color",
            "configuration.created",
            "configuration.description",
            "configuration.fadeOutTime",
            "configuration.file",
            "configuration.link",
            "configuration.section.annotation",
            "configuration.section.author",
            "configuration.section.model",
            "configuration.symbol",
            "configuration.title",
            "configuration.type",
            "configuration.version",
            // Download
            "download.downloaded",
            "download.error",
            "download.status",
            "download.title",
            "download.url",
            "download.urlHint",
            // History
            "history.clear.button",
            "history.clear.title",
            "history.section.title",
            "history.title",
            // Import
            "import.appleDocumentation",
            "import.fromFiles",
            "import.fromFilesHint",
            "import.fromURL",
            "import.fromURLHint",
            "import.learnMore",
            "import.onnxConversion",
            "import.onnxConversionHint",
            "import.success",
            "import.successWithInfo",
            "import.supportedModels",
            "import.supportedModelsInfo",
            "import.title",
            "import.validating",
            "import.wwdcCoreML",
            // Items
            "items.count",
            // Models
            "models.available.title",
            "models.empty.message",
            "models.empty.title",
            "models.title",
            // Sentry
            "sentry.config",
            "sentry.counters",
            "sentry.notAvailable",
            // Settings
            "settings.about",
            "settings.defaultPage",
            "settings.deleteCache",
            "settings.frequency",
            "settings.history",
            "settings.historyLimit",
            "settings.introduction",
            "settings.reopenLastPage",
            "settings.restore",
            "settings.restoreDefaults",
            "settings.runAtLaunch",
            "settings.section.annotation",
            "settings.section.debug",
            "settings.section.mlBrowser",
            "settings.section.webContent",
            "settings.sentry.title",
            "settings.showLabels",
            "settings.showNextTime",
            "settings.title",
            // Slideshow
            "slideshow.slide0.description",
            "slideshow.slide0.title",
            "slideshow.slide1.description",
            "slideshow.slide1.title",
            "slideshow.slide2.description",
            "slideshow.slide2.title",
            "slideshow.slide3.description",
            "slideshow.slide3.title",
            "slideshow.slide4.description",
            "slideshow.slide4.title",
            "slideshow.slide5.description",
            "slideshow.slide5.title",
            "slideshow.slide6.description",
            "slideshow.slide6.title",
            "slideshow.slide7.description",
            "slideshow.slide7.title",
            "slideshow.slide8.description",
            "slideshow.slide8.title",
            "slideshow.slide9.description",
            "slideshow.slide9.title",
            // Symbol
            "symbol.circle",
            "symbol.point",
            "symbol.square",
            // DownloadState
            "downloadState.cancelled",
            "downloadState.complete",
            "downloadState.downloading",
            "downloadState.failed",
            "downloadState.importFailed",
            "downloadState.imported",
            "downloadState.notStarted",
            "downloadState.paused",
            // Tab
            "tab.examples",
            "tab.web"
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
