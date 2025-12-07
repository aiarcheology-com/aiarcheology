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
}
