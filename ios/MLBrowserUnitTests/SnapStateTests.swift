//
//  SnapStateTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import Combine
@testable import ML_Browser

// MARK: - SnapAdjustment Tests

@MainActor
final class SnapAdjustmentTests: XCTestCase {
    
    // MARK: - Default Values Tests
    
    func testDefaultBrightness() {
        XCTAssertEqual(SnapAdjustment.defaultBrightness, 0.0)
    }
    
    func testDefaultContrast() {
        XCTAssertEqual(SnapAdjustment.defaultContrast, 1.0)
    }
    
    func testDefaultSaturation() {
        XCTAssertEqual(SnapAdjustment.defaultSaturation, 1.0)
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization_HasDefaultValues() {
        let adjustment = SnapAdjustment()
        
        XCTAssertEqual(adjustment.brightness, SnapAdjustment.defaultBrightness)
        XCTAssertEqual(adjustment.contrast, SnapAdjustment.defaultContrast)
        XCTAssertEqual(adjustment.saturation, SnapAdjustment.defaultSaturation)
    }
    
    // MARK: - Property Modification Tests
    
    func testBrightnessCanBeModified() {
        let adjustment = SnapAdjustment()
        adjustment.brightness = 0.5
        XCTAssertEqual(adjustment.brightness, 0.5)
    }
    
    func testContrastCanBeModified() {
        let adjustment = SnapAdjustment()
        adjustment.contrast = 1.5
        XCTAssertEqual(adjustment.contrast, 1.5)
    }
    
    func testSaturationCanBeModified() {
        let adjustment = SnapAdjustment()
        adjustment.saturation = 0.8
        XCTAssertEqual(adjustment.saturation, 0.8)
    }
    
    // MARK: - Edge Cases
    
    func testBrightnessNegativeValue() {
        let adjustment = SnapAdjustment()
        adjustment.brightness = -1.0
        XCTAssertEqual(adjustment.brightness, -1.0)
    }
    
    func testContrastZeroValue() {
        let adjustment = SnapAdjustment()
        adjustment.contrast = 0.0
        XCTAssertEqual(adjustment.contrast, 0.0)
    }
    
    func testSaturationZeroValue() {
        let adjustment = SnapAdjustment()
        adjustment.saturation = 0.0
        XCTAssertEqual(adjustment.saturation, 0.0)
    }
}

// MARK: - SnapState Tests

@MainActor
final class SnapStateTests: XCTestCase {
    
    var settings: Settings!
    var sut: SnapState!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        sut = SnapState(settings: settings)
        cancellables = []
    }
    
    override func tearDown() async throws {
        sut.stopTimer()
        cancellables = nil
        sut = nil
        settings = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        XCTAssertNotNil(sut.settings)
        XCTAssertNil(sut.timerCancellable)
        XCTAssertNil(sut.snap)
        XCTAssertFalse(sut.delayedTimer)
    }
    
    // MARK: - Timer Tests
    
    func testStartTimer_SetsTimerCancellable() {
        XCTAssertNil(sut.timerCancellable)
        
        sut.startTimer(for: 1)
        
        XCTAssertNotNil(sut.timerCancellable)
    }
    
    func testStopTimer_ClearsTimerCancellable() {
        sut.startTimer(for: 1)
        XCTAssertNotNil(sut.timerCancellable)
        
        sut.stopTimer()
        
        XCTAssertNil(sut.timerCancellable)
    }
    
    func testStartTimer_CalledTwice_DoesNotCreateNewTimer() {
        sut.startTimer(for: 1)
        XCTAssertNotNil(sut.timerCancellable)
        
        // Call startTimer again - guard should prevent recreation
        sut.startTimer(for: 1)
        
        // Timer should still be active (not nil)
        XCTAssertNotNil(sut.timerCancellable)
    }
    
    func testStopTimer_CalledWithoutStart_DoesNotCrash() {
        XCTAssertNil(sut.timerCancellable)
        
        // Should not crash
        sut.stopTimer()
        
        XCTAssertNil(sut.timerCancellable)
    }
    
    // MARK: - Combined Publishers Tests
    
    func testRequestSnapshot_PublishesRunScopedRequest() {
        let expectation = XCTestExpectation(description: "Combined publisher received value")
        var received: SnapshotRequest?

        sut.combinedPublishers
            .sink { request in
                received = request
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.requestSnapshot(for: 42)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(received?.runID, 42)
        XCTAssertEqual(received?.sequence, 1)
    }

    func testStartTimer_ImmediatelyPublishesRunScopedRequest() {
        let expectation = XCTestExpectation(description: "Timer's initial request")
        var received: SnapshotRequest?

        sut.combinedPublishers
            .sink { request in
                received = request
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.startTimer(for: 99)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(received?.runID, 99)
        XCTAssertEqual(received?.sequence, 1)
    }
    
    // MARK: - Snap Property Tests
    
    func testSnap_InitiallyNil() {
        XCTAssertNil(sut.snap)
    }
    
    func testSnap_CanBeSet() {
        let image = UIImage(systemName: "star") ?? UIImage()
        let snapshot = Snapshot(image: image)
        
        sut.snap = snapshot
        
        XCTAssertNotNil(sut.snap)
    }
}
