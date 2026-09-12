//
//  DataControllerTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 07.12.25.
//

import XCTest
import Combine
import CoreData
@testable import ML_Browser

@MainActor
final class DataControllerTests: XCTestCase {
    
    var cancellables: Set<AnyCancellable> = []
    
    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    /// Polls for a condition to become true with a timeout, useful for testing async Core Data merges.
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds (default: 1.0)
    ///   - pollInterval: Time between polls in nanoseconds (default: 10ms)
    ///   - condition: The condition to check
    /// - Returns: True if condition became true within timeout, false otherwise
    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        pollInterval: UInt64 = 10_000_000,
        condition: () -> Bool
    ) async -> Bool {
        let startTime = Date()
        while !condition() && Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return condition()
    }
    
    // MARK: - Initialization Tests
    
    func testDataController_InMemory_IsStoreLoadedImmediately() {
        let dataController = DataController(inMemory: true)
        
        // In-memory stores load synchronously, so isStoreLoaded should be true immediately
        XCTAssertTrue(dataController.isStoreLoaded)
    }
    
    func testDataController_InMemory_ContainerIsNotNil() {
        let dataController = DataController(inMemory: true)
        
        XCTAssertNotNil(dataController.container)
        XCTAssertEqual(dataController.container.name, DataController.containerName)
    }
    
    func testDataController_InMemory_ViewContextIsAvailable() {
        let dataController = DataController(inMemory: true)
        
        XCTAssertNotNil(dataController.container.viewContext)
    }
    
    // MARK: - awaitStoreReady Tests
    
    func testAwaitStoreReady_WhenAlreadyLoaded_ReturnsImmediately() async {
        let dataController = DataController(inMemory: true)
        XCTAssertTrue(dataController.isStoreLoaded)
        
        // This should return immediately since store is already loaded
        await dataController.awaitStoreReady()
        
        XCTAssertTrue(dataController.isStoreLoaded)
    }
    
    func testAwaitStoreReady_InMemory_CompletesSuccessfully() async {
        let dataController = DataController(inMemory: true)
        
        await dataController.awaitStoreReady()
        
        XCTAssertTrue(dataController.isStoreLoaded)
    }
    
    // MARK: - isStoreLoaded Publisher Tests
    
    func testIsStoreLoaded_PublishesTrue_WhenStoreLoads() {
        let expectation = XCTestExpectation(description: "isStoreLoaded publishes true")
        
        let dataController = DataController(inMemory: true)
        
        // swiftlint:disable:next first_where
        dataController.$isStoreLoaded
            .filter { $0 }
            .first()
            .sink { isLoaded in
                XCTAssertTrue(isLoaded)
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Container Name Tests
    
    func testContainerName_IsMLBrowser() {
        XCTAssertEqual(DataController.containerName, "MLBrowser")
    }
    
    // MARK: - performBackgroundTask Tests
    
    func testPerformBackgroundTask_ConfiguresContextWithDefaultMergePolicy() async {
        let dataController = DataController(inMemory: true)
        let expectation = XCTestExpectation(description: "Background task executes")
        
        dataController.performBackgroundTask { context in
            XCTAssertEqual(context.mergePolicy as? NSMergePolicy, NSMergePolicy.mergeByPropertyObjectTrump)
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testPerformBackgroundTask_ConfiguresContextWithCustomMergePolicy() async {
        let dataController = DataController(inMemory: true)
        let expectation = XCTestExpectation(description: "Background task executes")
        
        dataController.performBackgroundTask(mergePolicy: .mergeByPropertyStoreTrump) { context in
            XCTAssertEqual(context.mergePolicy as? NSMergePolicy, NSMergePolicy.mergeByPropertyStoreTrump)
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testPerformBackgroundTask_ExecutesOnBackgroundThread() async {
        let dataController = DataController(inMemory: true)
        let expectation = XCTestExpectation(description: "Background task executes")
        
        dataController.performBackgroundTask { _ in
            XCTAssertFalse(Thread.isMainThread, "Background task should not execute on main thread")
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testPerformBackgroundTask_MergesChangesToViewContext() async {
        let dataController = DataController(inMemory: true)
        await dataController.awaitStoreReady()
        
        // Create an entity in background context
        let expectation = XCTestExpectation(description: "Background task completes")
        let entityId = UUID()
        
        dataController.performBackgroundTask { context in
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = entityId
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example.com")
            entry.transition(to: .draft)
            entry.transition(to: .ready)
            do {
                try WebHistoryEntry.save(in: context)
            } catch {
                XCTFail("Saving in background context failed: \(error)")
            }
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        // Wait for merge completion using helper method
        let merged = await waitForCondition {
            WebHistoryEntry.count(
                in: dataController.container.viewContext,
                predicate: NSPredicate(format: "entityId == %@", entityId as CVarArg)
            ) > 0
        }
        
        XCTAssertTrue(merged, "Background context changes should be merged to viewContext within timeout")
    }
    
    // MARK: - setupContextMerging Tests
    
    func testSetupContextMerging_EnablesAutomaticMerging() async {
        let dataController = DataController(inMemory: true)
        await dataController.awaitStoreReady()
        
        XCTAssertTrue(
            dataController.container.viewContext.automaticallyMergesChangesFromParent,
            "viewContext should have automaticallyMergesChangesFromParent enabled"
        )
    }
    
    func testSetupContextMerging_SetsCorrectMergePolicy() async {
        let dataController = DataController(inMemory: true)
        await dataController.awaitStoreReady()

        XCTAssertEqual(
            dataController.container.viewContext.mergePolicy as? NSMergePolicy,
            NSMergePolicy.mergeByPropertyObjectTrump,
            "viewContext should have mergeByPropertyObjectTrump merge policy"
        )
    }

    // MARK: - CoreDataManageable.count Tests

    func testCount_ReturnsZero_WhenNoEntitiesExist() {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        let count = WebHistoryEntry.count(in: context)

        XCTAssertEqual(count, 0)
    }

    func testCount_ReturnsCorrectNumber_AfterCreatingEntities() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create 3 entities
        for index in 0..<3 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        let count = WebHistoryEntry.count(in: context)

        XCTAssertEqual(count, 3)
    }

    func testCount_WithPredicate_FiltersCorrectly() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        let targetId = UUID()

        // Create 3 entities, one with a specific ID
        for index in 0..<3 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = index == 1 ? targetId : UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        let predicate = NSPredicate(format: "entityId == %@", targetId as CVarArg)
        let filteredCount = WebHistoryEntry.count(in: context, predicate: predicate)

        XCTAssertEqual(filteredCount, 1)
    }

    func testCount_WithPredicate_ReturnsZero_WhenNoMatch() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create some entities
        for index in 0..<3 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        // Search for a non-existent ID
        let nonExistentId = UUID()
        let predicate = NSPredicate(format: "entityId == %@", nonExistentId as CVarArg)
        let filteredCount = WebHistoryEntry.count(in: context, predicate: predicate)

        XCTAssertEqual(filteredCount, 0)
    }

    func testCount_ReflectsChanges_AfterDeletion() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create 3 entities
        var entityIds: [UUID] = []
        for index in 0..<3 {
            let entry = WebHistoryEntry.create(in: context)
            let id = UUID()
            entry.entityId = id
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
            entityIds.append(id)
        }
        try WebHistoryEntry.save(in: context)

        XCTAssertEqual(WebHistoryEntry.count(in: context), 3)

        // Delete one entity
        WebHistoryEntry.delete(entityIds[0], in: context)

        XCTAssertEqual(WebHistoryEntry.count(in: context), 2)
    }

    func testCount_ReflectsChanges_AfterDeleteAll() throws {
        // Note: NSBatchDeleteRequest (used by deleteAll) does not work with NSInMemoryStoreType.
        // We test the count behavior by manually deleting entities one by one instead.
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create entities and track their IDs
        var entityIds: [UUID] = []
        for index in 0..<5 {
            let entry = WebHistoryEntry.create(in: context)
            let id = UUID()
            entry.entityId = id
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
            entityIds.append(id)
        }
        try WebHistoryEntry.save(in: context)

        XCTAssertEqual(WebHistoryEntry.count(in: context), 5)

        // Delete all entities one by one (works with in-memory store)
        for id in entityIds {
            WebHistoryEntry.delete(id, in: context)
        }

        XCTAssertEqual(WebHistoryEntry.count(in: context), 0)
    }

    func testCount_WorksWithDifferentEntityTypes() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create WebHistoryEntry entities
        for index in 0..<2 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        // Create DeepConfiguration entities
        for _ in 0..<3 {
            let config = DeepConfiguration.create(in: context)
            config.entityId = UUID()
            config.creationDate_ = .now
        }
        try DeepConfiguration.save(in: context)

        // Verify counts are independent
        XCTAssertEqual(WebHistoryEntry.count(in: context), 2)
        XCTAssertEqual(DeepConfiguration.count(in: context), 3)
    }

    func testCount_WithNilPredicate_CountsAll() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        // Create entities
        for index in 0..<4 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        // Explicitly pass nil predicate
        let count = WebHistoryEntry.count(in: context, predicate: nil)

        XCTAssertEqual(count, 4)
    }

    func testCount_WithComplexPredicate_FiltersCorrectly() throws {
        let dataController = DataController(inMemory: true)
        let context = dataController.container.viewContext

        let cutoffDate = Date()

        // Create entities with different dates
        for index in 0..<5 {
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            // Some before cutoff, some after
            entry.creationDate_ = index < 3
                ? cutoffDate.addingTimeInterval(-Double(index + 1) * 3600)
                : cutoffDate.addingTimeInterval(Double(index) * 3600)
            entry.page = URL(string: "https://example\(index).com")
        }
        try WebHistoryEntry.save(in: context)

        // Count entries created before cutoff
        let predicate = NSPredicate(format: "creationDate_ < %@", cutoffDate as NSDate)
        let countBeforeCutoff = WebHistoryEntry.count(in: context, predicate: predicate)

        XCTAssertEqual(countBeforeCutoff, 3)
    }
}
