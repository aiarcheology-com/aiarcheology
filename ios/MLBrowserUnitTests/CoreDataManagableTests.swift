//
//  CoreDataManagableTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

// Helper entity for testing protocol default implementations
// We'll use WebHistoryEntry since it conforms to CoreDataManagableWithState
// and we have it in the model.

final class CoreDataManagableTests: XCTestCase {

    var testStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }
    
    func testLifecycleTransitions() {
        let context = testStack.viewContext
        let item = WebHistoryEntry(context: context)
        
        XCTAssertEqual(item.lifeCycle, .empty) // See awakeFromInsert
        
        // Transition to Draft
        XCTAssertEqual(item.transition(to: .draft), .draft)
        XCTAssertEqual(item.lifeCycle, .draft)
        
        // Transition to Ready
        XCTAssertEqual(item.transition(to: .ready), .ready)
        XCTAssertEqual(item.lifeCycle, .ready)
        
        // Transition to Deprecated
        XCTAssertEqual(item.transition(to: .deprecated), .deprecated)
        XCTAssertEqual(item.lifeCycle, .deprecated)
        
        // Resurrection (Deprecated -> Empty)
        XCTAssertEqual(item.transition(to: .empty), .empty)
        XCTAssertEqual(item.lifeCycle, .empty)
    }
    
    func testInvalidTransition() {
        let context = testStack.viewContext
        let item = WebHistoryEntry(context: context)
        item.lifeCycle = .undefined
        
        // Undefined -> Ready is NOT allowed directly
        let result = item.transition(to: .ready)
        XCTAssertEqual(result, .undefined) // Should stay undefined
    }
    
    func testSuggestedNextState() {
        let context = testStack.viewContext
        let item = WebHistoryEntry(context: context)
        item.lifeCycle = .draft
        
        // Invalid item (missing date/url) -> should stay draft or empty
        // WebHistoryEntry validation: needs date and valid URL if present.
        // Let's make it invalid.
        item.creationDate_ = nil
        XCTAssertFalse(item.validationReport().isValid)
        
        // If invalid, suggested next is draft (if has changes) or empty?
        // Implementation: return valid ? .ready : (hasChanges ? .draft : .empty)
        // It has changes (we just set creationDate_ = nil, though it was nil).
        // Let's ensure it has changes.
        item.page = URL(string: "http://example.com")
        XCTAssertTrue(item.hasChanges)
        
        XCTAssertEqual(item.suggestedNextState(), .draft)
        
        // Make it valid
        item.creationDate_ = Date()
        XCTAssertTrue(item.validationReport().isValid)
        
        XCTAssertEqual(item.suggestedNextState(), .ready)
    }
    
    func testCRUDOperations() throws {
        let context = testStack.viewContext

        // Create
        let item = WebHistoryEntry.create(in: context)
        let id = item.entityId
        XCTAssertNotNil(id)

        // Update
        try WebHistoryEntry.update(id, in: context) { entry in
            entry.page = URL(string: "https://updated.com")
        }

        let fetched = WebHistoryEntry.select(id, in: context)
        XCTAssertEqual(fetched?.page?.absoluteString, "https://updated.com")

        // Delete
        WebHistoryEntry.delete(id, in: context)
        let deleted = WebHistoryEntry.select(id, in: context)
        XCTAssertNil(deleted)
    }

    func testCountMethod() throws {
        let context = testStack.viewContext

        // Initially should be empty
        XCTAssertEqual(WebHistoryEntry.count(in: context), 0)

        // Create some entries
        let entry1 = WebHistoryEntry.create(in: context)
        entry1.page = URL(string: "https://example1.com")
        entry1.creationDate_ = Date()

        let entry2 = WebHistoryEntry.create(in: context)
        entry2.page = URL(string: "https://example2.com")
        entry2.creationDate_ = Date()

        let entry3 = WebHistoryEntry.create(in: context)
        entry3.page = URL(string: "https://example3.com")
        entry3.creationDate_ = Date()

        try WebHistoryEntry.save(in: context)

        // Should count 3 entries
        XCTAssertEqual(WebHistoryEntry.count(in: context), 3)

        // Test with predicate
        let predicate = NSPredicate(format: "page.absoluteString CONTAINS %@", "example2")
        XCTAssertEqual(WebHistoryEntry.count(in: context, predicate: predicate), 1)

        // Delete one and verify count
        WebHistoryEntry.delete(entry1.entityId, in: context)
        XCTAssertEqual(WebHistoryEntry.count(in: context), 2)
    }

    func testSelectAllWithFetchLimit() throws {
        let context = testStack.viewContext

        // Create 5 entries
        for i in 1...5 {
            let entry = WebHistoryEntry.create(in: context)
            entry.page = URL(string: "https://example\(i).com")
            entry.creationDate_ = Date()
        }
        try WebHistoryEntry.save(in: context)

        // Fetch all - should return 5
        let allEntries = WebHistoryEntry.selectAll(in: context)
        XCTAssertEqual(allEntries.count, 5)

        // Fetch with limit - should return only 3
        let limitedEntries = WebHistoryEntry.selectAll(in: context, fetchLimit: 3, fetchBatchSize: 20)
        XCTAssertEqual(limitedEntries.count, 3)
    }
}
