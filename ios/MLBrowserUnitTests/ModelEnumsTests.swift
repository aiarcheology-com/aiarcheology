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
    
    /// **The raw value is a storage format, not a label** (AIA-0620).
    ///
    /// `DeepConfiguration.selectedSymbol` decodes this straight out of the Core Data attribute
    /// `selectedSymbol_` and falls back to `.circle` on anything it does not recognise. So renaming
    /// this string would not fail loudly — it would silently reset every existing user's annotation
    /// shape to a circle, on a preference they chose deliberately. It must stay "Square" even
    /// though the label no longer says so.
    func testSquareRawValue() {
        XCTAssertEqual(AnnotationSymbol.square.rawValue, "Square")
    }

    /// The other half of the same contract: what the user *reads* is "Rectangle", because the case
    /// has always drawn `ObservationRectangleView` — a bounding rectangle, never a square.
    ///
    /// Asserted against the localized name rather than the catalog so the two cannot drift: if
    /// someone repoints `.square` at a different key, or renames the raw value to match the label,
    /// exactly one of these two tests fails and names which mistake was made.
    func testSquareIsLabelledRectangle_whileItsStoredValueStaysSquare() {
        XCTAssertEqual(AnnotationSymbol.square.localizedName, L10n.Symbol.rectangle)
        XCTAssertEqual(AnnotationSymbol.square.rawValue, "Square")
        XCTAssertNotEqual(AnnotationSymbol.square.localizedName, AnnotationSymbol.square.rawValue)
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
    
    // MARK: - Identifiable Tests
    
    func testWebId() {
        XCTAssertEqual(AppMode.web.id, .web)
    }
    
    // MARK: - TabOrder Tests
    
    func testTabOrder() {
        let tabOrder = AppMode.tabOrder
        XCTAssertEqual(tabOrder, [.web])
    }
    
    func testTabOrderContainsWeb() {
        XCTAssertTrue(AppMode.tabOrder.contains(.web))
    }
    
    /// `tabOrder` is what `ContentView` iterates, so anything absent from it never renders.
    /// AIA-0898 removed the gallery case precisely because it had always been absent here; this
    /// asserts the list stays deliberate rather than growing a case that would surface untested UI.
    func testTabOrderIsExactlyTheRenderedTabs() {
        XCTAssertEqual(AppMode.tabOrder, AppMode.allCases,
                       "every AppMode case must render; a case outside tabOrder is unreachable UI")
    }
    
    // MARK: - Codable Tests
    
    func testEncodeDecode_Web() throws {
        let original = AppMode.web
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppMode.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
    
    // MARK: - Hashable Tests
    
    func testHashable() {
        var set: Set<AppMode> = []
        set.insert(.web)
        set.insert(.web) // Duplicate

        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set.contains(.web))
    }
    
    // MARK: - Init from RawValue Tests
    
    func testInitFromRawValue_Valid() {
        XCTAssertEqual(AppMode(rawValue: 0), .web)
    }
    
    func testInitFromRawValue_Invalid() {
        // 1 was `.gallery`, removed in AIA-0898. AppMode is held in memory only
        // (`AppChromeState.mode`) and never persisted, so no stored value decodes to it.
        XCTAssertNil(AppMode(rawValue: 1))
        XCTAssertNil(AppMode(rawValue: 999))
        XCTAssertNil(AppMode(rawValue: -1))
    }
}
