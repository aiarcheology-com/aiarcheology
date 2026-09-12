//
//  NSManagedObjectExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
import CoreData
@testable import ML_Browser

// MARK: - NSManagedObject+Extension Tests

@MainActor
final class NSManagedObjectExtensionsTests: XCTestCase {
    
    private var dataController: DataController!
    private var context: NSManagedObjectContext!
    
    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        context = dataController.container.viewContext
    }
    
    override func tearDown() async throws {
        context = nil
        dataController = nil
        try await super.tearDown()
    }
    
    // MARK: - isPersisted Tests
    
    func test_isPersisted_newUnsavedObject_returnsFalse() {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        
        XCTAssertFalse(entity.isPersisted)
    }
    
    func test_isPersisted_savedObject_returnsTrue() throws {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        try context.save()
        
        XCTAssertTrue(entity.isPersisted)
    }
    
    func test_isPersisted_afterObtainPermanentIDs_returnsTrue() throws {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        
        try context.obtainPermanentIDs(for: [entity])
        
        XCTAssertTrue(entity.isPersisted)
    }
    
    // MARK: - isNew Tests
    
    func test_isNew_freshlyCreatedObject_returnsTrue() {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        
        XCTAssertTrue(entity.isNew)
    }
    
    func test_isNew_savedObject_returnsFalse() throws {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        try context.save()
        
        XCTAssertFalse(entity.isNew)
    }
    
    func test_isNew_fetchedObject_returnsFalse() throws {
        // Create and save
        let entity = WebHistoryEntry(context: context)
        let entityId = UUID()
        entity.entityId = entityId
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        try context.save()
        
        // Fetch it back
        let fetchRequest: NSFetchRequest<WebHistoryEntry> = WebHistoryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "entityId == %@", entityId as CVarArg)
        
        let results = try context.fetch(fetchRequest)
        let fetchedEntity = try XCTUnwrap(results.first)
        
        XCTAssertFalse(fetchedEntity.isNew)
    }
    
    func test_isNew_objectWithPermanentID_returnsFalse() throws {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        
        // Obtain permanent ID without saving
        try context.obtainPermanentIDs(for: [entity])
        
        // isNew should be false because isPersisted is now true
        XCTAssertFalse(entity.isNew)
    }
    
    // MARK: - Relationship between isPersisted and isNew
    
    func test_newObject_isInsertedAndNotPersisted() {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        
        XCTAssertTrue(entity.isInserted)
        XCTAssertFalse(entity.isPersisted)
        XCTAssertTrue(entity.isNew) // isInserted && !isPersisted
    }
    
    func test_savedObject_isNotInsertedAndIsPersisted() throws {
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        try context.save()
        
        XCTAssertFalse(entity.isInserted)
        XCTAssertTrue(entity.isPersisted)
        XCTAssertFalse(entity.isNew)
    }
}

// MARK: - NSManagedObjectContext+Extensions Tests

// Note: NSBatchDeleteRequest doesn't work with in-memory Core Data stores.
// The executeAndMergeChanges extension requires an SQLite-backed store.
// Integration tests with a real SQLite store should be used to test this functionality.
