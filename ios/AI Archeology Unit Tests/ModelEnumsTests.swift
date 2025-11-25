//
//  ModelEnumsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

// MARK: - AnnotationSymbol Tests

final class AnnotationSymbolTests: XCTestCase {
    
    // MARK: - Raw Value Tests
    
    func testPointRawValue() {
        XCTAssertEqual(AnnotationSymbol.point.rawValue, "Point")
    }
    
    func testSquareRawValue() {
        XCTAssertEqual(AnnotationSymbol.square.rawValue, "Square")
    }
    
    func testCircleRawValue() {
        XCTAssertEqual(AnnotationSymbol.circle.rawValue, "Circle")
    }
    
    // MARK: - Identifiable Tests
    
    func testPointId() {
        XCTAssertEqual(AnnotationSymbol.point.id, "Point")
    }
    
    func testSquareId() {
        XCTAssertEqual(AnnotationSymbol.square.id, "Square")
    }
    
    func testCircleId() {
        XCTAssertEqual(AnnotationSymbol.circle.id, "Circle")
    }
    
    // MARK: - CaseIterable Tests
    
    func testAllCases() {
        let allCases = AnnotationSymbol.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.point))
        XCTAssertTrue(allCases.contains(.square))
        XCTAssertTrue(allCases.contains(.circle))
    }
    
    // MARK: - Init from RawValue Tests
    
    func testInitFromRawValue_Point() {
        let symbol = AnnotationSymbol(rawValue: "Point")
        XCTAssertEqual(symbol, .point)
    }
    
    func testInitFromRawValue_Square() {
        let symbol = AnnotationSymbol(rawValue: "Square")
        XCTAssertEqual(symbol, .square)
    }
    
    func testInitFromRawValue_Circle() {
        let symbol = AnnotationSymbol(rawValue: "Circle")
        XCTAssertEqual(symbol, .circle)
    }
    
    func testInitFromRawValue_Invalid() {
        let symbol = AnnotationSymbol(rawValue: "Invalid")
        XCTAssertNil(symbol)
    }
    
    func testInitFromRawValue_CaseSensitive() {
        let symbol = AnnotationSymbol(rawValue: "point")
        XCTAssertNil(symbol, "Raw value should be case-sensitive")
    }
}

// MARK: - AppMode Tests

final class AppModeTests: XCTestCase {
    
    // MARK: - Raw Value Tests
    
    func testWebRawValue() {
        XCTAssertEqual(AppMode.web.rawValue, 0)
    }
    
    func testGalleryRawValue() {
        XCTAssertEqual(AppMode.gallery.rawValue, 1)
    }
    
    // MARK: - Identifiable Tests
    
    func testWebId() {
        XCTAssertEqual(AppMode.web.id, .web)
    }
    
    func testGalleryId() {
        XCTAssertEqual(AppMode.gallery.id, .gallery)
    }
    
    // MARK: - TabOrder Tests
    
    func testTabOrder() {
        let tabOrder = AppMode.tabOrder
        XCTAssertEqual(tabOrder, [.web])
    }
    
    func testTabOrderContainsWeb() {
        XCTAssertTrue(AppMode.tabOrder.contains(.web))
    }
    
    func testTabOrderDoesNotContainGallery() {
        // Based on current implementation, gallery is not in tabOrder
        XCTAssertFalse(AppMode.tabOrder.contains(.gallery))
    }
    
    // MARK: - Codable Tests
    
    func testEncodeDecode_Web() throws {
        let original = AppMode.web
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppMode.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
    
    func testEncodeDecode_Gallery() throws {
        let original = AppMode.gallery
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppMode.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
    
    // MARK: - Hashable Tests
    
    func testHashable() {
        var set: Set<AppMode> = []
        set.insert(.web)
        set.insert(.gallery)
        set.insert(.web) // Duplicate
        
        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(.web))
        XCTAssertTrue(set.contains(.gallery))
    }
    
    // MARK: - Init from RawValue Tests
    
    func testInitFromRawValue_Valid() {
        XCTAssertEqual(AppMode(rawValue: 0), .web)
        XCTAssertEqual(AppMode(rawValue: 1), .gallery)
    }
    
    func testInitFromRawValue_Invalid() {
        XCTAssertNil(AppMode(rawValue: 999))
        XCTAssertNil(AppMode(rawValue: -1))
    }
}

