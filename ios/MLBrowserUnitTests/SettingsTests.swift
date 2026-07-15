//
//  SettingsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import SwiftUI
@testable import ML_Browser

@MainActor
final class SettingsTests: XCTestCase {
    
    var settings: Settings!
    
    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
    }
    
    override func tearDown() async throws {
        // Reset to defaults for clean state
        settings.reset()
        settings = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testSettings_DefaultHistorySize_Is30() {
        settings.reset()
        XCTAssertEqual(settings.historySize, 30)
    }
    
    func testSettings_DefaultReopenLastPage_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.reopenLastPage)
    }
    
    func testSettings_DefaultSnapAfterAppStart_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.snapAfterAppStart)
    }
    
    func testSettings_DefaultSnapFrequency_Is3() {
        settings.reset()
        XCTAssertEqual(settings.snapFrequency, 3.0)
    }
    
    func testSettings_DefaultShowIdentifiers_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.showIdentifiers)
    }
    
    func testSettings_DefaultRemoveAnnotationOnDrag_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.removeAnnotationOnDrag)
    }

    func testSettings_DefaultPyramidTiling_IsTrue() {
        settings.reset()
        XCTAssertTrue(settings.pyramidTiling)
    }

    func testSettings_PyramidTiling_PersistsAndResets() {
        settings.reset()
        settings.pyramidTiling = false
        // The registered default is true, so a fresh instance reading false proves the
        // value was actually persisted (bool(forKey:) alone returns false for a
        // missing key and would pass vacuously).
        XCTAssertFalse(Settings().pyramidTiling)
        settings.reset()
        XCTAssertTrue(settings.pyramidTiling)
        XCTAssertTrue(Settings().pyramidTiling)
    }

    func testSettings_PyramidTiling_ReadsLegacyTiledDetectionKey() {
        // Backward-compat (AIA-0426): pyramidTiling persists under the legacy "tiledDetection" key,
        // so an existing user's value survives the rename. Seed the raw key and read it back fresh.
        UserDefaults.standard.set(false, forKey: "tiledDetection")
        XCTAssertFalse(Settings().pyramidTiling)
        settings.reset()
    }

    func testSettings_DefaultGrid3x3Tiling_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.grid3x3Tiling)
    }

    func testSettings_Grid3x3Tiling_PersistsAndResets() {
        settings.reset()
        settings.grid3x3Tiling = true
        XCTAssertTrue(Settings().grid3x3Tiling)
        settings.reset()
        XCTAssertFalse(settings.grid3x3Tiling)
        XCTAssertFalse(Settings().grid3x3Tiling)
    }

    func testSettings_DefaultTiledBorders_IsFalse() {
        settings.reset()
        XCTAssertFalse(settings.tiledBorders)
    }

	func testSettings_OptionalAnalyticsDefaultsOffAndResets() {
		settings.reset()
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)

		settings.analyticsEnabled = true
		settings.analyticsChoiceMade = true
		XCTAssertTrue(Settings().analyticsEnabled)
		XCTAssertTrue(Settings().analyticsChoiceMade)

		settings.reset()
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
	}

    func testSettings_TiledBorders_PersistsAndResets() {
        settings.reset()
        settings.tiledBorders = true
        XCTAssertTrue(Settings().tiledBorders)
        settings.reset()
        XCTAssertFalse(settings.tiledBorders)
        XCTAssertFalse(Settings().tiledBorders)
    }

    func testSettings_TilingSchemes_ReflectsToggles() {
        settings.reset() // pyramid on, 3x3 off
        XCTAssertEqual(settings.tilingSchemes, .pyramid)
        settings.grid3x3Tiling = true
        XCTAssertEqual(settings.tilingSchemes, [.pyramid, .grid3x3])
        settings.pyramidTiling = false
        XCTAssertEqual(settings.tilingSchemes, .grid3x3)
        settings.grid3x3Tiling = false
        XCTAssertEqual(settings.tilingSchemes, [])
    }
    
    func testSettings_DefaultPage_IsGoogle() {
        settings.reset()
        XCTAssertEqual(settings.defaultPage?.absoluteString, "https://www.google.com")
    }
    
    func testSettings_DefaultEntityId_IsNotNil() {
        settings.reset()
        XCTAssertNotNil(settings.entityId)
    }
    
    // MARK: - Property Update Tests
    
    func testSettings_UpdatingHistorySize_PersistsValue() {
        settings.historySize = 50
        XCTAssertEqual(settings.historySize, 50)
        
        settings.historySize = 100
        XCTAssertEqual(settings.historySize, 100)
    }
    
    func testSettings_UpdatingSnapFrequency_PersistsValue() {
        settings.snapFrequency = 5.0
        XCTAssertEqual(settings.snapFrequency, 5.0)
        
        settings.snapFrequency = 8.5
        XCTAssertEqual(settings.snapFrequency, 8.5)
    }
    
    func testSettings_UpdatingReopenLastPage_PersistsValue() {
        settings.reopenLastPage = true
        XCTAssertTrue(settings.reopenLastPage)
        
        settings.reopenLastPage = false
        XCTAssertFalse(settings.reopenLastPage)
    }
    
    func testSettings_UpdatingSnapAfterAppStart_PersistsValue() {
        settings.snapAfterAppStart = true
        XCTAssertTrue(settings.snapAfterAppStart)
        
        settings.snapAfterAppStart = false
        XCTAssertFalse(settings.snapAfterAppStart)
    }
    
    func testSettings_UpdatingShowIdentifiers_PersistsValue() {
        settings.showIdentifiers = true
        XCTAssertTrue(settings.showIdentifiers)
        
        settings.showIdentifiers = false
        XCTAssertFalse(settings.showIdentifiers)
    }
    
    func testSettings_UpdatingRemoveAnnotationOnDrag_PersistsValue() {
        settings.removeAnnotationOnDrag = true
        XCTAssertTrue(settings.removeAnnotationOnDrag)
        
        settings.removeAnnotationOnDrag = false
        XCTAssertFalse(settings.removeAnnotationOnDrag)
    }
    
    func testSettings_UpdatingDefaultPage_PersistsValue() {
        let newURL = URL(string: "https://www.example.com")
        settings.defaultPage = newURL
        XCTAssertEqual(settings.defaultPage, newURL)
    }
    
    func testSettings_UpdatingLastPage_PersistsValue() {
        let lastPageURL = URL(string: "https://www.lastvisited.com")
        settings.lastPage = lastPageURL
        XCTAssertEqual(settings.lastPage, lastPageURL)
    }
    
    func testSettings_UpdatingEntityId_PersistsValue() {
        let newUUID = UUID()
        settings.entityId = newUUID
        XCTAssertEqual(settings.entityId, newUUID)
    }
    
    func testSettings_UpdatingIsFirstLaunch_PersistsValue() {
        settings.isFirstLaunch = false
        XCTAssertFalse(settings.isFirstLaunch)
        
        settings.isFirstLaunch = true
        XCTAssertTrue(settings.isFirstLaunch)
    }
    
    func testSettings_UpdatingIsDetectionPaused_PersistsValue() {
        settings.isDetectionPaused = true
        XCTAssertTrue(settings.isDetectionPaused)
        
        settings.isDetectionPaused = false
        XCTAssertFalse(settings.isDetectionPaused)
    }
    
    func testSettings_UpdatingResetHistory_PersistsValue() {
        settings.resetHistory = true
        XCTAssertTrue(settings.resetHistory)
        
        settings.resetHistory = false
        XCTAssertFalse(settings.resetHistory)
    }
    
    // MARK: - Validation Tests
    
    func testValidate_WithValidSnapFrequency_DoesNotThrow() {
        settings.snapFrequency = 5.0
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = UUID()
        
        XCTAssertNoThrow(try settings.validate())
    }
    
    func testValidate_SnapFrequencyTooLow_ThrowsError() {
        settings.snapFrequency = 0.5
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = UUID()
        
        XCTAssertThrowsError(try settings.validate()) { error in
            guard case ValidationError.invalidData(let message) = error else {
                XCTFail("Expected ValidationError.invalidData")
                return
            }
            XCTAssertTrue(message.contains("snapFrequency"))
        }
    }
    
    func testValidate_SnapFrequencyTooHigh_ThrowsError() {
        settings.snapFrequency = 15.0
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = UUID()
        
        XCTAssertThrowsError(try settings.validate()) { error in
            guard case ValidationError.invalidData(let message) = error else {
                XCTFail("Expected ValidationError.invalidData")
                return
            }
            XCTAssertTrue(message.contains("snapFrequency"))
        }
    }
    
    func testValidate_SnapFrequencyAtLowerBound_DoesNotThrow() {
        settings.snapFrequency = 1.0
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = UUID()
        
        XCTAssertNoThrow(try settings.validate())
    }
    
    func testValidate_SnapFrequencyAtUpperBound_DoesNotThrow() {
        settings.snapFrequency = 10.0
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = UUID()
        
        XCTAssertNoThrow(try settings.validate())
    }
    
    func testValidate_InvalidDefaultPageURL_ThrowsError() {
        settings.snapFrequency = 5.0
        settings.defaultPage = URL(string: "not-a-valid-url")
        settings.entityId = UUID()
        
        XCTAssertThrowsError(try settings.validate()) { error in
            guard case ValidationError.invalidData(let message) = error else {
                XCTFail("Expected ValidationError.invalidData")
                return
            }
            XCTAssertTrue(message.contains("defaultPage"))
        }
    }
    
    func testValidate_NilEntityId_ThrowsError() {
        settings.snapFrequency = 5.0
        settings.defaultPage = URL(string: "https://www.google.com")
        settings.entityId = nil
        
        XCTAssertThrowsError(try settings.validate()) { error in
            guard case ValidationError.invalidData(let message) = error else {
                XCTFail("Expected ValidationError.invalidData")
                return
            }
            XCTAssertTrue(message.contains("entityId"))
        }
    }
    
    func testValidate_NilDefaultPage_DoesNotThrow() {
        settings.snapFrequency = 5.0
        settings.defaultPage = nil
        settings.entityId = UUID()

        XCTAssertNoThrow(try settings.validate())
    }

    func testValidate_AboutBlankDefaultPage_DoesNotThrow() {
        // A blank home page is a supported state (AIA-0298): about:blank must not block dismiss.
        settings.snapFrequency = 5.0
        settings.defaultPage = URL(string: "about:blank")
        settings.entityId = UUID()

        XCTAssertNoThrow(try settings.validate())
    }

    func testValidate_DefaultPageWithoutHost_ThrowsError() {
        // A scheme-only URL ("https://") has no host and can never load, so it must fail
        // validation even though browserInputType may classify it as `.url` (AIA-0298).
        settings.snapFrequency = 5.0
        settings.defaultPage = URL(string: "https://")
        settings.entityId = UUID()

        XCTAssertThrowsError(try settings.validate()) { error in
            guard case ValidationError.invalidData(let message) = error else {
                XCTFail("Expected ValidationError.invalidData")
                return
            }
            XCTAssertTrue(message.contains("defaultPage"))
        }
    }

    // MARK: - Reset Tests
    
    func testReset_RestoresAllDefaultValues() {
        // Modify all values first
        settings.isDetectionPaused = true
        settings.historySize = 100
        settings.reopenLastPage = true
        settings.isFirstLaunchMarked = true
        settings.isFirstLaunch = false
        settings.showIdentifiers = true
        settings.snapAfterAppStart = true
        settings.snapFrequency = 7.0
        settings.resetHistory = true
        settings.defaultPage = URL(string: "https://changed.com")
        settings.removeAnnotationOnDrag = true
        settings.lastPage = URL(string: "https://lastpage.com")
        
        // Reset
        settings.reset()
        
        // Verify defaults are restored
        XCTAssertFalse(settings.isDetectionPaused)
        XCTAssertEqual(settings.historySize, 30)
        XCTAssertFalse(settings.reopenLastPage)
        XCTAssertFalse(settings.isFirstLaunchMarked)
        XCTAssertTrue(settings.isFirstLaunch)
        XCTAssertFalse(settings.showIdentifiers)
        XCTAssertFalse(settings.snapAfterAppStart)
        XCTAssertEqual(settings.snapFrequency, 3.0)
        XCTAssertFalse(settings.resetHistory)
        XCTAssertEqual(settings.defaultPage?.absoluteString, "https://www.google.com")
        XCTAssertFalse(settings.removeAnnotationOnDrag)
        XCTAssertNotNil(settings.entityId)
    }
    
    func testReset_CreatesNewEntityId() {
        let originalEntityId = settings.entityId
        settings.reset()
        
        // Entity ID should be regenerated
        XCTAssertNotNil(settings.entityId)
        XCTAssertNotEqual(settings.entityId, originalEntityId)
    }
    
    // MARK: - Integration Tests
    
    func testSettings_MultiplePropertyChanges_AllPersist() {
        settings.historySize = 50
        settings.snapFrequency = 5.5
        settings.reopenLastPage = true
        settings.showIdentifiers = true
        
        XCTAssertEqual(settings.historySize, 50)
        XCTAssertEqual(settings.snapFrequency, 5.5)
        XCTAssertTrue(settings.reopenLastPage)
        XCTAssertTrue(settings.showIdentifiers)
    }
    
    func testSettings_AfterValidReset_PassesValidation() {
        settings.reset()
        
        XCTAssertNoThrow(try settings.validate())
    }
    
    // MARK: - ValidationError Tests

    func testValidationError_InvalidData_ContainsMessage() {
        let error = ValidationError.invalidData("Test message")

        switch error {
        case .invalidData(let message):
            XCTAssertEqual(message, "Test message")
        }
    }

}
