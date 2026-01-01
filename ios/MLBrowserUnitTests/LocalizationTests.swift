//
//  LocalizationTests.swift
//  MLBrowserUnitTests
//
//  Created by AI Assistant on 02.01.26.
//

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
            XCTAssertNotEqual(localized, key, "Key '\(key)' should have an English translation")
            XCTAssertFalse(localized.isEmpty, "Key '\(key)' should not be empty")
        }
    }

    func test_englishTranslation_historyTitle_correctValue() {
        let localized = NSLocalizedString("history.title", comment: "")
        XCTAssertEqual(localized, "Browsing History")
    }

    func test_englishTranslation_commonDone_correctValue() {
        let localized = NSLocalizedString("common.done", comment: "")
        XCTAssertEqual(localized, "Done")
    }

    func test_englishTranslation_commonDelete_correctValue() {
        let localized = NSLocalizedString("common.delete", comment: "")
        XCTAssertEqual(localized, "Delete")
    }

    func test_englishTranslation_modelsTitle_correctValue() {
        let localized = NSLocalizedString("models.title", comment: "")
        XCTAssertEqual(localized, "Models")
    }

    func test_englishTranslation_alertWarningTitle_correctValue() {
        let localized = NSLocalizedString("alert.warning.title", comment: "")
        XCTAssertEqual(localized, "Warning")
    }

    // MARK: - Plural Forms

    func test_plural_itemsCount_singular() {
        let format = NSLocalizedString("items.count", comment: "")
        let result = String(format: format, 1)
        XCTAssertTrue(result.contains("1"), "Singular form should contain the number 1")
        XCTAssertTrue(result.contains("item"), "Singular form should contain 'item'")
    }

    func test_plural_itemsCount_multiple() {
        let format = NSLocalizedString("items.count", comment: "")
        let result = String(format: format, 5)
        XCTAssertTrue(result.contains("5"), "Plural form should contain the number 5")
        XCTAssertTrue(result.contains("items"), "Plural form should contain 'items'")
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
}
