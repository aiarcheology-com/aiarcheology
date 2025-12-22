//
//  WebHistoryTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import XCTest
@testable import ML_Browser

@MainActor
final class WebHistoryTests: XCTestCase {

    var testStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }
    
    func testIsValidPageURL() {
        // We can't access the private static method directly, but we can test it via validationReport
        // or if we make it internal. Since it's private, we'll test via validationReport.
        
        let context = testStack.viewContext
        let entry = WebHistoryEntry(context: context)
        entry.creationDate_ = Date()
        entry.lifeCycle = .draft
        
        // Valid HTTP
        entry.page = URL(string: "http://example.com")
        XCTAssertTrue(entry.validationReport().isValid)
        
        // Valid HTTPS
        entry.page = URL(string: "https://example.com/path")
        XCTAssertTrue(entry.validationReport().isValid)
        
        // Valid File
        entry.page = URL(fileURLWithPath: "/path/to/file")
        XCTAssertTrue(entry.validationReport().isValid)
        
        // Invalid Scheme
        entry.page = URL(string: "ftp://example.com")
        XCTAssertFalse(entry.validationReport().isValid)
        
        // Empty Host (HTTP)
        entry.page = URL(string: "http://")
        XCTAssertFalse(entry.validationReport().isValid)
    }
    
    func testValidationReport_MissingDate() {
        let context = testStack.viewContext
        let entry = WebHistoryEntry(context: context)
        entry.lifeCycle = .draft
        entry.page = URL(string: "https://example.com")
        entry.creationDate_ = nil
        
        let report = entry.validationReport()
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "creationDate" } ?? false)
    }
    
    func testComparable() {
        let context = testStack.viewContext
        let entry1 = WebHistoryEntry(context: context)
        let entry2 = WebHistoryEntry(context: context)
        
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        
        entry1.creationDate_ = date1
        entry2.creationDate_ = date2
        
        XCTAssertTrue(entry1 < entry2)
        XCTAssertFalse(entry2 < entry1)
        
        // Test nil date handling
        let entryNil = WebHistoryEntry(context: context)
        entryNil.creationDate_ = nil
        
        // Nil is considered "smaller" (earlier) or handled as per implementation?
        // Implementation: case (nil, _): return true. So nil < any date.
        XCTAssertTrue(entryNil < entry1)
    }
}
