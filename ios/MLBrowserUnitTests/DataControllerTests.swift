//
//  DataControllerTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 07.12.25.
//

import XCTest
import Combine
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
        
        dataController.performBackgroundTask { context in
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
        var entityId: UUID?
        
        dataController.performBackgroundTask { context in
            let entry = WebHistoryEntry.create(in: context)
            entry.entityId = UUID()
            entry.creationDate_ = .now
            entry.page = URL(string: "https://example.com")
            entry.transition(to: .draft)
            entry.transition(to: .ready)
            entityId = entry.entityId
            WebHistoryEntry.save(in: context)
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        // Wait for merge completion using helper method
        let merged = await waitForCondition {
            WebHistoryEntry.count(
                in: dataController.container.viewContext,
                predicate: NSPredicate(format: "entityId == %@", entityId! as CVarArg)
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
}

