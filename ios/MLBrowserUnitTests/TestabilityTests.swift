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
    
}
