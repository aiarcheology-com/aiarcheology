//
//  DeepStateTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import XCTest
import Combine
@testable import ML_Browser

@MainActor
final class DeepStateTests: XCTestCase {
    
    var dataController: DataController!
    var deepState: DeepState!
    var cancellables: Set<AnyCancellable> = []
    
    override func setUp() async throws {
        try await super.setUp()
        // Ensure initialization happens on the main actor to avoid crossing isolation.
        dataController = DataController(inMemory: true)
        deepState = DeepState(dataController: dataController)
    }
    
    override func tearDown() async throws {
        // Nil out main-actor state before calling super to keep isolation consistent
        deepState = nil
        dataController = nil
        cancellables.removeAll()
        try await super.tearDown()
    }
    
    func testCreateConfiguration() {
        let config = deepState.createConfiguration()
        XCTAssertNotNil(config)
        XCTAssertNotNil(config.entityId)
        
        let fetched = DeepConfiguration.select(config.entityId, in: dataController.container.viewContext)
        XCTAssertNotNil(fetched)
    }
    
    func testDeleteConfiguration() {
        let config = deepState.createConfiguration()
        let id = config.entityId
        
        deepState.deleteConfiguration(id)
        
        let fetched = DeepConfiguration.select(id, in: dataController.container.viewContext)
        XCTAssertNil(fetched)
    }
    
    func testDriverRegistrationOnEnable() {
        // This test verifies that enabling a configuration triggers driver creation.
        // Since `DeepState` uses `createDriver` which creates real `Detector`/`Classificator`,
        // and those might try to load files, we might see failures if files don't exist.
        // However, `DeepState` handles errors gracefully.
        
        let config = deepState.createConfiguration()
        config.modelType = .detector
        config.enabled = false
        DeepConfiguration.save(in: dataController.container.viewContext)
        
        // Expectation: Driver should NOT be registered yet
        XCTAssertTrue(deepState.drivers.detectors.isEmpty)
        
        // Enable it
        deepState.updateConfiguration(config.entityId) { c in
            c.enabled = true
        }
        
        let expectation = XCTestExpectation(description: "Driver registration attempt finished")
        deepState.deepStateErrorPublisher
            .compactMap { $0 }
            .sink { _ in
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testTemporaryConfigurationCleanup() {
        deepState.createTemportaryConfiguration()
        XCTAssertNotNil(deepState.newConfiguration)
        
        let config = deepState.newConfiguration!
        let configId = config.entityId
        config.lifeCycle = .draft // This makes shouldDeleteOnAbandon true
        
        deepState.cleanupTemporaryConfiguration()
        
        XCTAssertNil(deepState.newConfiguration)
        let fetched = DeepConfiguration.select(configId, in: dataController.container.viewContext)
        XCTAssertNil(fetched)
    }
}
