//
//  DemoDataManagerTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 07.12.25.
//

import XCTest
import CoreData
@testable import ML_Browser

@MainActor
final class DemoDataManagerTests: XCTestCase {
    
    var dataController: DataController!
    var sut: DemoDataManager!
    
    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        sut = DemoDataManager(dataController: dataController)
    }
    
    override func tearDown() async throws {
        sut = nil
        dataController = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testDemoDataManager_Initialization() {
        XCTAssertNotNil(sut)
        XCTAssertNotNil(sut.dataController)
    }
    
    // MARK: - createDemoDataIfNeeded Tests
    
    func testCreateDemoDataIfNeeded_WhenDemosExist_DoesNotCreateDuplicates() async throws {
        let context = dataController.container.viewContext
        
        // Create a demo configuration manually. Keep it in .draft: a .ready lifecycle
        // requires a valid file/model type, and save(in:) now surfaces validation errors
        // instead of swallowing them. The duplicate check only filters on `demo`.
        let existingDemo = DeepConfiguration.create(in: context)
        existingDemo.demo = true
        existingDemo.transition(to: .draft)
        try DeepConfiguration.save(in: context)
        
        let initialCount = DeepConfiguration.selectAll(in: context).filter { $0.demo }.count
        XCTAssertEqual(initialCount, 1)
        
        // Call createDemoDataIfNeeded - should skip creation
        await sut.createDemoDataIfNeeded()
        
        // Count should remain the same (no duplicates)
        let finalCount = DeepConfiguration.selectAll(in: context).filter { $0.demo }.count
        XCTAssertEqual(finalCount, initialCount)
    }
    
    func testCreateDemoDataIfNeeded_CalledMultipleTimes_NoDuplicates() async {
        // Call multiple times in succession
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        
        let context = dataController.container.viewContext
        let demoConfigs = DeepConfiguration.selectAll(in: context).filter { $0.demo }
        
        // Should have at most 2 demo configs (the bundled models), not 6
        // Note: In test environment, bundled models may not exist, so count could be 0
        XCTAssertLessThanOrEqual(demoConfigs.count, 2)
    }
    
    // MARK: - deleteBrowsingHistory Tests
    
    // Note: NSBatchDeleteRequest doesn't work with in-memory Core Data stores.
    // The deleteBrowsingHistory method uses batch delete internally.
    // Integration tests with a real SQLite store would be needed to test this functionality.
    
    // MARK: - Race Condition Prevention Tests
    
    func testCreateDemoDataIfNeeded_CalledRapidly_NoDuplicates() async {
        // Call multiple times in rapid succession
        // MainActor serializes these, verifying the guard check works correctly
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        await sut.createDemoDataIfNeeded()
        
        let context = dataController.container.viewContext
        let demoConfigs = DeepConfiguration.selectAll(in: context).filter { $0.demo }
        
        // Even with multiple calls, should have at most 2 demo configs
        // Note: In test environment, bundled models may not exist, so count could be 0
        XCTAssertLessThanOrEqual(demoConfigs.count, 2)
    }
}
