//
//  LowerPriorityTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

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
