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
    
    func testCRUDOperations() {
        let context = testStack.viewContext
        
        // Create
        let item = WebHistoryEntry.create(in: context)
        let id = item.entityId
        XCTAssertNotNil(id)
        
        // Update
        WebHistoryEntry.update(id, in: context) { entry in
            entry.page = URL(string: "https://updated.com")
        }
        
        let fetched = WebHistoryEntry.select(id, in: context)
        XCTAssertEqual(fetched?.page?.absoluteString, "https://updated.com")
        
        // Delete
        WebHistoryEntry.delete(id, in: context)
        let deleted = WebHistoryEntry.select(id, in: context)
        XCTAssertNil(deleted)
    }
}
