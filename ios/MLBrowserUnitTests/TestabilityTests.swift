//
//  TestabilityTests.swift
//  AI Archeology Unit Tests
//
//  Created by AI Agent on 26.11.25.
//

import XCTest
import SwiftUI
@testable import ML_Browser

final class TestabilityTests: XCTestCase {

    // MARK: - TestabilityIdentification Tests

    enum MockID: String, TestabilityIdentification {
        case testCase
    }

    func testIdentification_DefaultValues() {
        let id = MockID.testCase()
        // Expected: _AIA:MockID.TestCase
        XCTAssertEqual(id, "_AIA:MockID.TestCase")
        XCTAssertTrue(Testability.isValid(id))
    }

    func testIdentification_WithAllParameters() {
        let id = MockID.testCase(section: 1, index: 2, parent: "ParentView", label: "MyLabel")
        // Expected: _AIA:MockID.#MyLabelTestCase#1#2_inParentView
        XCTAssertEqual(id, "_AIA:MockID.#MyLabelTestCase#1#2_inParentView")
        XCTAssertTrue(Testability.isValid(id))
    }

    func testIdentification_WithLabel() {
        let id = MockID.testCase(label: "CustomLabel")
        XCTAssertEqual(id, "_AIA:MockID.#CustomLabelTestCase")
    }

    func testIdentification_WithIndex() {
        let id = MockID.testCase(index: 5)
        XCTAssertEqual(id, "_AIA:MockID.TestCase#5")
    }

    func testIdentification_WithSection() {
        let id = MockID.testCase(section: 3)
        XCTAssertEqual(id, "_AIA:MockID.TestCase#3")
    }

    func testIdentification_WithParent() {
        let id = MockID.testCase(parent: "Container")
        XCTAssertEqual(id, "_AIA:MockID.TestCase_inContainer")
    }

    // MARK: - Testability Validation Tests

    func testIsValid_ValidID() {
        XCTAssertTrue(Testability.isValid("_AIA:SomeID"))
    }

    func testIsValid_InvalidID_NoPrefix() {
        XCTAssertFalse(Testability.isValid("SomeID"))
    }

    func testIsValid_InvalidID_WrongPrefix() {
        XCTAssertFalse(Testability.isValid("_BIA:SomeID"))
    }

    func testIsValid_Nil() {
        XCTAssertFalse(Testability.isValid(nil))
    }

    // MARK: - UITestLaunchConfiguration deltas

    @MainActor
    func test_applyPageScenario_blank_clearsHomeAndLastPageRouting() {
        let settings = Settings()
        defer { settings.reset() }
        settings.defaultPage = URL(string: UITestLaunchConfiguration.baselineHome)
        settings.reopenLastPage = true
        settings.lastPage = URL(string: "https://example.org/previous")

        var config = UITestLaunchConfiguration()
        config.pageScenario = .blank
        UITestLaunchConfiguration.applyPageScenario(config, to: settings)

        XCTAssertNil(settings.defaultPage)
        XCTAssertFalse(settings.reopenLastPage)
    }

    @MainActor
    func test_applyPageScenario_last_seedsReopenLastPage() {
        let settings = Settings()
        defer { settings.reset() }
        settings.reopenLastPage = false
        settings.lastPage = nil

        var config = UITestLaunchConfiguration()
        config.pageScenario = .last
        config.lastPage = "https://example.org/resume"
        UITestLaunchConfiguration.applyPageScenario(config, to: settings)

        XCTAssertTrue(settings.reopenLastPage)
        XCTAssertEqual(settings.lastPage, URL(string: "https://example.org/resume"))
    }

    @MainActor
    func test_applyPageScenario_homeOverride_writesDefaultPage() {
        let settings = Settings()
        defer { settings.reset() }
        settings.defaultPage = URL(string: UITestLaunchConfiguration.baselineHome)

        var config = UITestLaunchConfiguration()
        config.pageScenario = .home
        config.defaultPageOverride = "https://example.org/custom-home"
        UITestLaunchConfiguration.applyPageScenario(config, to: settings)

        XCTAssertEqual(settings.defaultPage, URL(string: "https://example.org/custom-home"))
    }

    @MainActor
    func test_applyDetectionAndAnalyticsDeltas_writesDetectionAndAnalyticsFields() {
        let settings = Settings()
        defer { settings.reset() }
        settings.fullscreenDetection = false
        settings.disableDetectionAnimations = false
        settings.snapFrequency = 3.0
        settings.analyticsEnabled = false
        settings.analyticsChoiceMade = true

        var config = UITestLaunchConfiguration()
        config.fullscreenDetection = true
        config.disableDetectionAnimations = true
        config.snapFrequency = 7.0
        config.analyticsScenario = .prompt
        UITestLaunchConfiguration.applyDetectionAndAnalyticsDeltas(config, to: settings)

        XCTAssertTrue(settings.fullscreenDetection)
        XCTAssertTrue(settings.disableDetectionAnimations)
        XCTAssertEqual(settings.snapFrequency, 7.0)
        XCTAssertFalse(settings.analyticsEnabled)
        XCTAssertFalse(settings.analyticsChoiceMade)

        config.analyticsScenario = .enabled
        UITestLaunchConfiguration.applyDetectionAndAnalyticsDeltas(config, to: settings)
        XCTAssertTrue(settings.analyticsEnabled)
    }

    // MARK: - Free-access expiry seed (AIA-0984)

    func test_freeAccessSeedConflict_refusesEveryCombinationTheSeedCannotHonour() {
        var config = UITestLaunchConfiguration()
        XCTAssertNil(UITestLaunchConfiguration.freeAccessSeedConflict(in: config), "no seed, nothing to refuse")
        config.freeAccessAnchorAgeDays = 20
        XCTAssertNil(UITestLaunchConfiguration.freeAccessSeedConflict(in: config), "the aged seed alone is unaffected")

        config.freeAccessEndsInSeconds = 90
        XCTAssertEqual(
            UITestLaunchConfiguration.freeAccessSeedConflict(in: config),
            "freeAccessEndsInSeconds and freeAccessAnchorAgeDays both seed the anchor; set one"
        )

        config.freeAccessAnchorAgeDays = nil
        XCTAssertNil(UITestLaunchConfiguration.freeAccessSeedConflict(in: config))
        config.freeAccessDay0Unshown = true
        XCTAssertEqual(
            UITestLaunchConfiguration.freeAccessSeedConflict(in: config),
            "freeAccessEndsInSeconds seeds the day-0 screen as shown; freeAccessDay0Unshown cannot apply"
        )

        config.freeAccessDay0Unshown = false
        XCTAssertNil(UITestLaunchConfiguration.freeAccessSeedConflict(in: config))
    }

    @MainActor
    func test_applyDetectionAndAnalyticsDeltas_freeAccessEndsInSeconds_seedsTheFastStore() throws {
        let settings = Settings()
        let store = settings.persistenceStore
        // The host app's store: put back whatever anchor it held.
        let hostAnchor = store.object(forKey: FreeAccessAnchorService.defaultsKey)
        defer { store.set(hostAnchor, forKey: FreeAccessAnchorService.defaultsKey) }
        store.removeObject(forKey: FreeAccessAnchorService.defaultsKey)

        var config = UITestLaunchConfiguration()
        config.freeAccessEndsInSeconds = 120
        let before = Date()
        UITestLaunchConfiguration.applyDetectionAndAnalyticsDeltas(config, to: settings)

        let data = try XCTUnwrap(store.data(forKey: FreeAccessAnchorService.defaultsKey))
        let record = try JSONDecoder().decode(FreeAccessWindow.Record.self, from: data)
        XCTAssertGreaterThanOrEqual(record.grantedAt, before)
        XCTAssertEqual(record.expiresAt.timeIntervalSince(record.grantedAt), 120)
        XCTAssertTrue(record.day0Shown)
    }
    
}
