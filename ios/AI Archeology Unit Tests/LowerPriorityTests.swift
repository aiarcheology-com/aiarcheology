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
    
    func test_initialization_inMemory() {
        let sut = DataController(inMemory: true)
        
        XCTAssertNotNil(sut.container)
        XCTAssertEqual(sut.container.name, DataController.containerName)
    }
    
    func test_containerName() {
        XCTAssertEqual(DataController.containerName, "MLBrowser")
    }
    
    func test_inMemoryStore_hasCorrectStoreType() {
        let sut = DataController(inMemory: true)
        
        let storeDescription = sut.container.persistentStoreDescriptions.first
        XCTAssertEqual(storeDescription?.type, NSInMemoryStoreType)
    }
    
    func test_viewContext_isAvailable() {
        let sut = DataController(inMemory: true)
        
        XCTAssertNotNil(sut.container.viewContext)
    }
    
    func test_viewContext_canPerformOperations() {
        let sut = DataController(inMemory: true)
        let context = sut.container.viewContext
        
        let entity = WebHistoryEntry(context: context)
        entity.entityId = UUID()
        entity.creationDate_ = Date()
        entity.page = URL(string: "https://example.com")
        
        XCTAssertNoThrow(try context.save())
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
    
    func test_initialization() {
        XCTAssertNotNil(sut.settings)
        XCTAssertNotNil(sut.dataController)
    }
    
    // Note: testDeleteBrowsingHistory is not included because NSBatchDeleteRequest
    // is not supported with in-memory CoreData stores.
    
    func test_createDemoEntities_onlyRunsOnFirstLaunch() async {
        settings.isFirstLaunch = false
        
        sut.createDemoEntities()
        
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    
    func test_createDemoEntities_setsFirstLaunchMarked() async {
        settings.isFirstLaunch = true
        settings.isFirstLaunchMarked = false
        
        sut.createDemoEntities()
        
        XCTAssertTrue(settings.isFirstLaunchMarked)
        XCTAssertFalse(settings.isFirstLaunch)
    }
}

// MARK: - Gallery FileManager Tests (will be removed with Gallery)

final class GalleryFileManagerExtensionsTests: XCTestCase {
    
    var testDirectory: URL!
    
    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
        super.tearDown()
    }
    
    func test_getContentsOfDirectory_emptyDirectory_returnsEmptyArray() {
        let contents = FileManager.default.getContentsOfDirectory(testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }
    
    func test_getContentsOfDirectory_withFiles_returnsFiles() {
        let file1 = testDirectory.appendingPathComponent("test1.txt")
        let file2 = testDirectory.appendingPathComponent("test2.txt")
        
        FileManager.default.createFile(atPath: file1.path, contents: Data())
        FileManager.default.createFile(atPath: file2.path, contents: Data())
        
        let contents = FileManager.default.getContentsOfDirectory(testDirectory)
        
        XCTAssertEqual(contents.count, 2)
    }
    
    func test_getContentsOfDirectory_invalidPath_returnsEmptyArray() {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path")
        let contents = FileManager.default.getContentsOfDirectory(invalidURL)
        XCTAssertTrue(contents.isEmpty)
    }
    
    func test_getContentsOfDirectory_fileNotDirectory_returnsEmptyArray() {
        let file = testDirectory.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        
        let contents = FileManager.default.getContentsOfDirectory(file)
        XCTAssertTrue(contents.isEmpty)
    }
}
