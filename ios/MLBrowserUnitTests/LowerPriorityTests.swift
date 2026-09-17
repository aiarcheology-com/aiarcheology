//
//  LowerPriorityTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

// MARK: - Snapshot Tests

final class SnapshotTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialization_SetsImage() {
        let image = UIImage(systemName: "star") ?? UIImage()
        let snapshot = Snapshot(image: image)

        XCTAssertNotNil(snapshot.image)
    }

    func testInitialization_SetsDateToNow() {
        let beforeCreation = Date()
        let image = UIImage(systemName: "star") ?? UIImage()
        let snapshot = Snapshot(image: image)
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(snapshot.date, beforeCreation)
        XCTAssertLessThanOrEqual(snapshot.date, afterCreation)
    }

    func testInitialization_WithDifferentImage() {
        let image1 = UIImage(systemName: "star") ?? UIImage()
        let image2 = UIImage(systemName: "circle") ?? UIImage()

        let snapshot1 = Snapshot(image: image1)
        let snapshot2 = Snapshot(image: image2)

        // Both should have their images set (we can't easily compare UIImages)
        XCTAssertNotNil(snapshot1.image)
        XCTAssertNotNil(snapshot2.image)
    }

    // MARK: - Date Tests

    func testDate_IsRecent() {
        let image = UIImage(systemName: "star") ?? UIImage()
        let snapshot = Snapshot(image: image)

        let timeDifference = Date().timeIntervalSince(snapshot.date)
        XCTAssertLessThan(timeDifference, 1.0, "Snapshot date should be within 1 second of creation")
    }

    func testDate_DifferentSnapshots_HaveDifferentDates() async {
        let image = UIImage(systemName: "star") ?? UIImage()
        let snapshot1 = Snapshot(image: image)

        // Small delay to ensure different timestamps
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let snapshot2 = Snapshot(image: image)

        XCTAssertNotEqual(snapshot1.date, snapshot2.date)
    }

    // MARK: - Image Tests

    func testImage_PreservesImageReference() {
        let originalImage = UIImage(systemName: "star") ?? UIImage()
        let snapshot = Snapshot(image: originalImage)

        // Should be the same image instance
        XCTAssertTrue(snapshot.image === originalImage)
    }

    func testImage_WithEmptyImage() {
        let emptyImage = UIImage()
        let snapshot = Snapshot(image: emptyImage)

        XCTAssertNotNil(snapshot.image)
    }
}
