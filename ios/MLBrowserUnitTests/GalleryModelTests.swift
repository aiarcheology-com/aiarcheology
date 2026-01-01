//
//  GalleryModelTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

// MARK: - ItemG Tests

final class ItemGTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testInitialization_SetsURL() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item = ItemG(url: url)
        
        XCTAssertEqual(item.url, url)
    }
    
    func testInitialization_GeneratesUniqueId() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item = ItemG(url: url)
        
        XCTAssertNotEqual(item.id, UUID.zeros())
    }
    
    func testInitialization_DifferentItemsHaveDifferentIds() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item1 = ItemG(url: url)
        let item2 = ItemG(url: url)
        
        XCTAssertNotEqual(item1.id, item2.id)
    }
    
    // MARK: - Identifiable Tests
    
    func testIdentifiable_IdIsUUID() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item = ItemG(url: url)
        
        // id should be a UUID (testing via type)
        let _: UUID = item.id
    }
    
    // MARK: - Equatable Tests
    
    func testEquatable_SameItem_IsEqual() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item = ItemG(url: url)
        
        XCTAssertEqual(item, item)
    }
    
    func testEquatable_DifferentItems_NotEqual() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item1 = ItemG(url: url)
        let item2 = ItemG(url: url)
        
        // Even with same URL, different IDs mean not equal
        XCTAssertNotEqual(item1, item2)
    }
    
    func testEquatable_DifferentURLs_NotEqual() {
        let item1 = ItemG(url: URL(fileURLWithPath: "/path/to/image1.jpg"))
        let item2 = ItemG(url: URL(fileURLWithPath: "/path/to/image2.jpg"))
        
        XCTAssertNotEqual(item1, item2)
    }
    
    // MARK: - URL Tests
    
    func testURL_PreservesFileExtension() {
        let url = URL(fileURLWithPath: "/path/to/image.jpg")
        let item = ItemG(url: url)
        
        XCTAssertEqual(item.url.pathExtension, "jpg")
    }
    
    func testURL_PreservesPath() {
        let url = URL(fileURLWithPath: "/path/to/subfolder/image.png")
        let item = ItemG(url: url)
        
        XCTAssertTrue(item.url.path.contains("subfolder"))
    }
}

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
