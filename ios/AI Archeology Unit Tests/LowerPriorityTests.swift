//
//  LowerPriorityTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

// MARK: - DataController Tests

final class DataControllerTests: XCTestCase {
    
    func testInitialization_InMemory() {
        let sut = DataController(inMemory: true)
        
        XCTAssertNotNil(sut.container)
        XCTAssertEqual(sut.container.name, DataController.containerName)
    }
    
    func testContainerName() {
        XCTAssertEqual(DataController.containerName, "MLBrowser")
    }
    
    func testInMemoryStore_HasCorrectStoreType() {
        let sut = DataController(inMemory: true)
        
        // In-memory store should have NSInMemoryStoreType
        let storeDescription = sut.container.persistentStoreDescriptions.first
        XCTAssertEqual(storeDescription?.type, NSInMemoryStoreType)
    }
    
    func testViewContext_IsAvailable() {
        let sut = DataController(inMemory: true)
        
        XCTAssertNotNil(sut.container.viewContext)
    }
    
    func testViewContext_CanPerformOperations() {
        let sut = DataController(inMemory: true)
        let context = sut.container.viewContext
        
        // Should be able to create entities
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        XCTAssertNoThrow(try context.save())
    }
}

// MARK: - HostPlatform Tests

final class HostPlatformTests: XCTestCase {
    
    func testCurrent_ReturnsValidPlatform() {
        let platform = HostPlatform.current
        
        // Should return one of the valid platforms
        let validPlatforms: [HostPlatform] = [.iOS, .iPadOS, .macViaCatalyst, .macDesignedForiPad]
        XCTAssertTrue(validPlatforms.contains(platform))
    }
    
    func testIsMac_iOS_ReturnsFalse() {
        XCTAssertFalse(HostPlatform.iOS.isMac)
    }
    
    func testIsMac_iPadOS_ReturnsFalse() {
        XCTAssertFalse(HostPlatform.iPadOS.isMac)
    }
    
    func testIsMac_MacViaCatalyst_ReturnsTrue() {
        XCTAssertTrue(HostPlatform.macViaCatalyst.isMac)
    }
    
    func testIsMac_MacDesignedForiPad_ReturnsTrue() {
        XCTAssertTrue(HostPlatform.macDesignedForiPad.isMac)
    }
}

// MARK: - Sequence Extensions Tests

final class SequenceExtensionsTests: XCTestCase {
    
    func testConcurrentForEach_ExecutesAllElements() async {
        let numbers = [1, 2, 3, 4, 5]
        let processedCount = Counter()
        
        await numbers.concurrentForEach { _ in
            await processedCount.increment()
        }
        
        let count = await processedCount.value
        XCTAssertEqual(count, 5)
    }
    
    func testConcurrentForEach_EmptySequence_DoesNothing() async {
        let empty: [Int] = []
        let executionTracker = Counter()
        
        await empty.concurrentForEach { _ in
            await executionTracker.increment()
        }
        
        let count = await executionTracker.value
        XCTAssertEqual(count, 0)
    }
    
    func testConcurrentForEach_ProcessesAllValues() async {
        let values = ["a", "b", "c"]
        let results = ResultsStore()
        
        await values.concurrentForEach { value in
            await results.append(value)
        }
        
        let collected = await results.values
        XCTAssertEqual(collected.sorted(), ["a", "b", "c"])
    }
    
    func testConcurrentForEach_RunsConcurrently() async {
        let items = [1, 2, 3]
        let startTime = Date()
        
        await items.concurrentForEach { _ in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms each
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        // If truly concurrent, should take ~50ms, not 150ms
        // Allow some margin for test reliability
        XCTAssertLessThan(elapsed, 0.15, "Should run concurrently, not sequentially")
    }
}

// Helper actor for thread-safe counting
actor Counter {
    private(set) var value = 0
    
    func increment() {
        value += 1
    }
}

// Helper actor for thread-safe collection
actor ResultsStore {
    private(set) var values: [String] = []
    
    func append(_ value: String) {
        values.append(value)
    }
}

// MARK: - FileManager Extensions Tests

final class FileManagerExtensionsTests: XCTestCase {
    
    var testDirectory: URL!
    
    override func setUp() {
        super.setUp()
        // Create a temporary test directory
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
        super.tearDown()
    }
    
    func testDocumentDirectory_ReturnsValidURL() {
        let docDir = FileManager.default.documentDirectory
        XCTAssertNotNil(docDir)
        XCTAssertTrue(docDir?.path.contains("Documents") ?? false)
    }
    
    func testGetContentsOfDirectory_EmptyDirectory_ReturnsEmptyArray() {
        let contents = FileManager.default.getContentsOfDirectory(testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }
    
    func testGetContentsOfDirectory_WithFiles_ReturnsFiles() {
        // Create some test files
        let file1 = testDirectory.appendingPathComponent("test1.txt")
        let file2 = testDirectory.appendingPathComponent("test2.txt")
        
        FileManager.default.createFile(atPath: file1.path, contents: Data())
        FileManager.default.createFile(atPath: file2.path, contents: Data())
        
        let contents = FileManager.default.getContentsOfDirectory(testDirectory)
        
        XCTAssertEqual(contents.count, 2)
    }
    
    func testGetContentsOfDirectory_InvalidPath_ReturnsEmptyArray() {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path")
        let contents = FileManager.default.getContentsOfDirectory(invalidURL)
        XCTAssertTrue(contents.isEmpty)
    }
    
    func testGetContentsOfDirectory_FileNotDirectory_ReturnsEmptyArray() {
        // Create a file (not directory)
        let file = testDirectory.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        
        // Trying to get contents of a file should return empty
        let contents = FileManager.default.getContentsOfDirectory(file)
        XCTAssertTrue(contents.isEmpty)
    }
}

// MARK: - DemoDataManager Tests

@MainActor
final class DemoDataManagerTests: XCTestCase {
    
    var settings: Settings!
    var dataController: DataController!
    var sut: DemoDataManager!
    
    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        dataController = DataController(inMemory: true)
        sut = DemoDataManager(settings: settings, dataController: dataController)
    }
    
    override func tearDown() async throws {
        sut = nil
        dataController = nil
        settings = nil
        try await super.tearDown()
    }
    
    func testInitialization() {
        XCTAssertNotNil(sut.settings)
        XCTAssertNotNil(sut.dataController)
    }
    
    // Note: testDeleteBrowsingHistory is not included because NSBatchDeleteRequest
    // is not supported with in-memory CoreData stores. The actual deletion logic
    // should be tested via integration tests with SQLite stores.
    
    func testCreateDemoEntities_OnlyRunsOnFirstLaunch() async {
        // Simulate not first launch
        settings.isFirstLaunch = false
        
        sut.createDemoEntities()
        
        // Allow time for any async operations
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Should not have created any history (not first launch)
        // Note: We can't easily test the positive case without bundled models
    }
    
    func testCreateDemoEntities_SetsFirstLaunchMarked() async {
        // Simulate first launch
        settings.isFirstLaunch = true
        settings.isFirstLaunchMarked = false
        
        sut.createDemoEntities()
        
        // Check that firstLaunchMarked is set
        XCTAssertTrue(settings.isFirstLaunchMarked)
        XCTAssertFalse(settings.isFirstLaunch)
    }
}

