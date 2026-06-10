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
    
    func testDriverRegistrationOnEnable() async throws {
        // This test verifies that enabling a configuration triggers driver creation.
        // Since `DeepState` uses `createDriver` which creates real `Detector`/`Classificator`,
        // and those might try to load files, we might see failures if files don't exist.
        // However, `DeepState` handles errors gracefully.
        
        let config = deepState.createConfiguration()
        config.modelType = .detector
        config.enabled = false
        try DeepConfiguration.save(in: dataController.container.viewContext)
        
        // Expectation: Driver should NOT be registered yet
        XCTAssertTrue(deepState.drivers.detectors.isEmpty)
        
        // Set up async stream BEFORE triggering the action to avoid race conditions
        let errorStream = deepState.deepStateErrorPublisher
            .compactMap { $0 }
            .toAsyncStream()
        
        // Enable it - this triggers async driver loading via CoreData notification
        deepState.updateConfiguration(config.entityId) { c in
            c.enabled = true
        }
        
        // Use async/await to wait for the error to be published with timeout
        // The driver loading will fail because there's no model file in tests
        let error = await withTimeoutOrNil(seconds: 5) {
            for await error in errorStream {
                return error
            }
            return nil
        }
        
        // Verify that an error was published (driver loading failed as expected)
        XCTAssertNotNil(error, "Expected an error to be published when driver loading fails")
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

// MARK: - Async Helpers for Tests

/// Thread-safe holder for AnyCancellable to bridge Combine → AsyncStream
private final class CancellableHolder: @unchecked Sendable {
    var cancellable: AnyCancellable?
    
    func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }
}

private extension Publisher where Failure == Never, Output: Sendable {
    /// Converts a Combine Publisher to an AsyncStream for use with async/await.
    func toAsyncStream() -> AsyncStream<Output> {
        let holder = CancellableHolder()
        
        return AsyncStream { continuation in
            holder.cancellable = self.sink { value in
                continuation.yield(value)
            }
            
            continuation.onTermination = { @Sendable _ in
                holder.cancel()
            }
        }
    }
}

/// Executes an async operation with a timeout. Returns nil if timeout is reached.
private func withTimeoutOrNil<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        
        // Return the first completed result (either the operation or timeout)
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}
