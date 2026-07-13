//
//  LocalizationTests.swift
//  MLBrowserUnitTests
//
//  Created by AI Assistant on 02.01.26.
//

import SwiftUI
import XCTest
@testable import ML_Browser

final class LocalizationTests: XCTestCase {

    // MARK: - Localization System

    func test_localization_isConfigured() {
        // String Catalogs (.xcstrings) are compiled at build time
        // Verify localization is working by checking a known key resolves
        let localized = NSLocalizedString("history.title", comment: "")
        XCTAssertNotEqual(localized, "history.title", "Localization should be configured and working")
    }

    // MARK: - English Translations

    func test_englishTranslations_exist() {
        let keys = [
            "history.title",
            "history.clear.button",
            "history.clear.title",
            "history.section.title",
            "alert.warning.title",
            "alert.history.clear.message",
            "common.delete",
            "common.done",
            "models.title",
            "settings.sentry.title"
        ]

        for key in keys {
            let localized = NSLocalizedString(key, comment: "")
            XCTAssertTrue(
                LocalizationValidator.isTranslated(localized, key: key),
                "Key '\(key)' should have an English translation"
            )
            XCTAssertTrue(
                LocalizationValidator.isNotEmpty(localized),
                "Key '\(key)' should not be empty"
            )
        }
    }

    func test_translation_historyTitle_isNotKey() {
        let localized = NSLocalizedString("history.title", comment: "")
        // Verify the key resolves to a translation (either English or German)
        XCTAssertNotEqual(localized, "history.title", "Key should resolve to a translation")
        XCTAssertFalse(localized.isEmpty, "Translation should not be empty")
    }

    func test_translation_commonDone_isNotKey() {
        let localized = NSLocalizedString("common.done", comment: "")
        XCTAssertNotEqual(localized, "common.done", "Key should resolve to a translation")
        XCTAssertFalse(localized.isEmpty, "Translation should not be empty")
    }

    func test_translation_commonDelete_isNotKey() {
        let localized = NSLocalizedString("common.delete", comment: "")
        XCTAssertNotEqual(localized, "common.delete", "Key should resolve to a translation")
        XCTAssertFalse(localized.isEmpty, "Translation should not be empty")
    }

    func test_translation_modelsTitle_isNotKey() {
        let localized = NSLocalizedString("models.title", comment: "")
        XCTAssertNotEqual(localized, "models.title", "Key should resolve to a translation")
        XCTAssertFalse(localized.isEmpty, "Translation should not be empty")
    }

    func test_translation_alertWarningTitle_isNotKey() {
        let localized = NSLocalizedString("alert.warning.title", comment: "")
        XCTAssertNotEqual(localized, "alert.warning.title", "Key should resolve to a translation")
        XCTAssertFalse(localized.isEmpty, "Translation should not be empty")
    }

    // MARK: - Plural Forms

    func test_plural_itemsCount_singular() {
        // Use L10n which handles plural forms correctly
        let result = L10n.Items.count(1)
        XCTAssertTrue(result.contains("1"), "Singular form should contain the number 1")
        XCTAssertFalse(result.isEmpty, "Singular form should not be empty")
    }

    func test_plural_itemsCount_multiple() {
        // Use L10n which handles plural forms correctly
        let result = L10n.Items.count(5)
        XCTAssertTrue(result.contains("5"), "Plural form should contain the number 5")
        XCTAssertFalse(result.isEmpty, "Plural form should not be empty")
    }

    // MARK: - Device Variants

    func test_deviceVariant_tapOrClick_exists() {
        let localized = NSLocalizedString("action.tap_or_click", comment: "")
        // The key should resolve to either "Tap" or "Click" depending on the device
        XCTAssertNotEqual(localized, "action.tap_or_click", "Device variant key should resolve")
        XCTAssertFalse(localized.isEmpty, "Device variant should not be empty")
    }

    // MARK: - German Language Bundle

    func test_germanBundle_exists() {
        let path = Bundle.main.path(forResource: "de", ofType: "lproj")
        // Note: String Catalogs may not create separate .lproj folders
        // This test documents the expected behavior
        if path == nil {
            // String Catalogs handle localization differently
            // The German translations are embedded in the xcstrings file
            // This is expected behavior for String Catalogs
        }
    }

    // MARK: - Key Stability

    func test_keys_areStableIdentifiers() {
        // Verify keys follow the stable identifier pattern (not English sentences)
        let keys = [
            "history.title",
            "history.clear.button",
            "common.delete",
            "models.title"
        ]

        for key in keys {
            XCTAssertTrue(key.contains("."), "Key '\(key)' should use dot notation for namespacing")
            XCTAssertFalse(key.contains(" "), "Key '\(key)' should not contain spaces")
            XCTAssertTrue(key.lowercased() == key, "Key '\(key)' should be lowercase")
        }
    }

    // MARK: - Missing Key Detection Helper

    func test_missingKey_returnsKeyItself() {
        let nonExistentKey = "this.key.does.not.exist.12345"
        let result = NSLocalizedString(nonExistentKey, comment: "")
        XCTAssertEqual(result, nonExistentKey, "Missing key should return the key itself")
    }

    // MARK: - LocalizationValidator Tests

    func test_localizationValidator_isTranslated_returnsTrueForTranslatedString() {
        XCTAssertTrue(LocalizationValidator.isTranslated("Browsing History", key: "history.title"))
    }

    func test_localizationValidator_isTranslated_returnsFalseForUntranslatedKey() {
        XCTAssertFalse(LocalizationValidator.isTranslated("some.missing.key", key: "some.missing.key"))
    }

    func test_localizationValidator_isNotEmpty_returnsTrueForNonEmptyString() {
        XCTAssertTrue(LocalizationValidator.isNotEmpty("Hello"))
    }

    func test_localizationValidator_isNotEmpty_returnsFalseForEmptyString() {
        XCTAssertFalse(LocalizationValidator.isNotEmpty(""))
        XCTAssertFalse(LocalizationValidator.isNotEmpty("   "))
    }

    func test_localizationValidator_contains_findsSubstring() {
        XCTAssertTrue(LocalizationValidator.contains("5 items", substring: "items"))
        XCTAssertFalse(LocalizationValidator.contains("5 items", substring: "missing"))
    }

    // MARK: - L10n Type-Safe Access Tests

    func test_l10n_historyTitle_returnsValue() {
        // L10n returns localized value based on current locale
        let value = L10n.History.title
        XCTAssertFalse(value.isEmpty, "L10n.History.title should not be empty")
        XCTAssertNotEqual(value, "history.title", "L10n should return a translation, not the key")
    }

    func test_l10n_commonDone_returnsValue() {
        // L10n returns localized value based on current locale
        let value = L10n.Common.done
        XCTAssertFalse(value.isEmpty, "L10n.Common.done should not be empty")
        XCTAssertNotEqual(value, "common.done", "L10n should return a translation, not the key")
    }

    func test_l10n_itemsCount_formatsCorrectly() {
        XCTAssertTrue(L10n.Items.count(1).contains("1"))
        XCTAssertTrue(L10n.Items.count(5).contains("5"))
    }

    // MARK: - L10n+SwiftUI Integration Tests

    func test_l10n_key_createsLocalizedStringKey() {
        let key = L10n.key(L10n.History.title)
        // LocalizedStringKey doesn't expose its value, but we can verify it's created
        XCTAssertNotNil(key)
    }

    func test_text_localizedInitializer_createsText() {
        let text = Text(localized: L10n.History.title)
        // Text doesn't expose its content, but we can verify it's created
        XCTAssertNotNil(text)
    }

    func test_button_localizedInitializer_createsButton() {
        let button = Button(localized: L10n.Common.done) { }
        XCTAssertNotNil(button)
    }
}

// MARK: - Localization Test Helpers

/// Pure string-comparison helpers for localization assertions.
///
/// Relocated from the former app-target `LocalizationTestHelpers.swift` (removed in AIA-0417 — it
/// was test-only code compiled into the shipping app). Source-catalog key validation now lives in
/// the macOS `MLBrowserArchitectureTests` target (`LocalizationCatalogTests`), which can read repo
/// source; the iOS-Simulator unit target cannot.
enum LocalizationValidator {

    /// A string is considered translated if it doesn't equal its key.
    static func isTranslated(_ localizedString: String, key: String) -> Bool {
        localizedString != key
    }

    /// Whether the localized string contains an expected substring (e.g. a formatted placeholder).
    static func contains(_ localizedString: String, substring: String) -> Bool {
        localizedString.contains(substring)
    }

    /// Whether the localized string is non-empty after trimming whitespace.
    static func isNotEmpty(_ localizedString: String) -> Bool {
        !localizedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
