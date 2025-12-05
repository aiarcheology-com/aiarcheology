//
//  FileManagerExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
@testable import ML_Browser

// MARK: - FileManager+Extensions Tests (Model Storage)

final class FileManagerExtensionsTests: XCTestCase {
    
    private var testDirectory: URL!
    private var testConfigurationId: UUID!
    
    override func setUp() {
        super.setUp()
        testConfigurationId = UUID()
        
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileManagerTests")
            .appendingPathComponent(UUID().uuidString)
        
        try? FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        
        if let configDir = FileManager.deepConfigurationDirectory(id: testConfigurationId) {
            try? FileManager.default.removeItem(at: configDir)
        }
        
        testDirectory = nil
        testConfigurationId = nil
        super.tearDown()
    }
    
    // MARK: - documentDirectory Tests
    
    func test_documentDirectory_returnsValidURL() {
        let documentDir = FileManager.default.documentDirectory
        
        XCTAssertNotNil(documentDir)
        XCTAssertTrue(documentDir?.path.contains("Documents") ?? false)
    }
    
    func test_documentDirectory_returnsConsistentValue() {
        let first = FileManager.default.documentDirectory
        let second = FileManager.default.documentDirectory
        
        XCTAssertEqual(first, second)
    }
    
    // MARK: - deepConfigurationDirectory Tests
    
    func test_deepConfigurationDirectory_returnsValidURL() {
        let configDir = FileManager.deepConfigurationDirectory(id: testConfigurationId)
        
        XCTAssertNotNil(configDir)
        XCTAssertTrue(configDir?.path.contains("Configurations") ?? false)
        XCTAssertTrue(configDir?.path.contains(testConfigurationId.uuidString) ?? false)
    }
    
    func test_deepConfigurationDirectory_differentIdsReturnDifferentPaths() {
        let id1 = UUID()
        let id2 = UUID()
        
        let dir1 = FileManager.deepConfigurationDirectory(id: id1)
        let dir2 = FileManager.deepConfigurationDirectory(id: id2)
        
        XCTAssertNotEqual(dir1, dir2)
    }
    
    func test_deepConfigurationDirectory_sameIdReturnsSamePath() {
        let dir1 = FileManager.deepConfigurationDirectory(id: testConfigurationId)
        let dir2 = FileManager.deepConfigurationDirectory(id: testConfigurationId)
        
        XCTAssertEqual(dir1, dir2)
    }
    
    // MARK: - moveModelToDocuments Tests
    
    func test_moveModelToDocuments_movesFileSuccessfully() throws {
        let sourceFile = testDirectory.appendingPathComponent("test_model.mlmodel")
        try "test content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.moveModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(destinationURL.path.contains(testConfigurationId.uuidString))
    }
    
    func test_moveModelToDocuments_preservesFileName() throws {
        let fileName = "my_custom_model.mlpackage"
        let sourceFile = testDirectory.appendingPathComponent(fileName)
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.moveModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        XCTAssertEqual(destinationURL.lastPathComponent, fileName)
    }
    
    func test_moveModelToDocuments_overwritesExistingFile() throws {
        let sourceFile1 = testDirectory.appendingPathComponent("model.mlmodel")
        try "content1".write(to: sourceFile1, atomically: true, encoding: .utf8)
        
        let destination1 = try FileManager.moveModelToDocuments(
            from: sourceFile1,
            configurationId: testConfigurationId
        )
        
        let sourceFile2 = testDirectory.appendingPathComponent("model.mlmodel")
        try "content2".write(to: sourceFile2, atomically: true, encoding: .utf8)
        
        let destination2 = try FileManager.moveModelToDocuments(
            from: sourceFile2,
            configurationId: testConfigurationId
        )
        
        XCTAssertEqual(destination1.path, destination2.path)
        
        let content = try String(contentsOf: destination2, encoding: .utf8)
        XCTAssertEqual(content, "content2")
    }
    
    func test_moveModelToDocuments_throwsForNonexistentSource() {
        let nonexistentFile = testDirectory.appendingPathComponent("nonexistent.mlmodel")
        
        XCTAssertThrowsError(
            try FileManager.moveModelToDocuments(
                from: nonexistentFile,
                configurationId: testConfigurationId
            )
        )
    }
    
    func test_moveModelToDocuments_createsIntermediateDirectories() throws {
        let sourceFile = testDirectory.appendingPathComponent("model.mlmodel")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let freshId = UUID()
        
        let destinationURL = try FileManager.moveModelToDocuments(
            from: sourceFile,
            configurationId: freshId
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        
        if let configDir = FileManager.deepConfigurationDirectory(id: freshId) {
            try? FileManager.default.removeItem(at: configDir)
        }
    }
    
    // MARK: - copyModelToDocuments Tests
    
    func test_copyModelToDocuments_copiesFileSuccessfully() throws {
        let sourceFile = testDirectory.appendingPathComponent("test_model.mlmodel")
        try "test content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.copyModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }
    
    func test_copyModelToDocuments_preservesSourceContent() throws {
        let expectedContent = "original model data"
        let sourceFile = testDirectory.appendingPathComponent("model.mlmodel")
        try expectedContent.write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.copyModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        let copiedContent = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(copiedContent, expectedContent)
    }
    
    func test_copyModelToDocuments_overwritesExistingFile() throws {
        let sourceFile = testDirectory.appendingPathComponent("model.mlmodel")
        try "original".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        _ = try FileManager.copyModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        try "updated".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destination = try FileManager.copyModelToDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        let content = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(content, "updated")
    }
    
    func test_copyModelToDocuments_throwsForNonexistentSource() {
        let nonexistentFile = testDirectory.appendingPathComponent("nonexistent.mlmodel")
        
        XCTAssertThrowsError(
            try FileManager.copyModelToDocuments(
                from: nonexistentFile,
                configurationId: testConfigurationId
            )
        )
    }
    
    // MARK: - storeModelInDocuments Tests
    
    func test_storeModelInDocuments_copiesByDefault() throws {
        let sourceFile = testDirectory.appendingPathComponent("model.mlmodel")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }
    
    func test_storeModelInDocuments_returnsOriginalURLIfAlreadyInDocuments() throws {
        guard let configDir = FileManager.deepConfigurationDirectory(id: testConfigurationId) else {
            XCTFail("Could not get configuration directory")
            return
        }
        
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let existingFile = configDir.appendingPathComponent("existing_model.mlmodel")
        try "content".write(to: existingFile, atomically: true, encoding: .utf8)
        
        let resultURL = try FileManager.storeModelInDocuments(
            from: existingFile,
            configurationId: testConfigurationId
        )
        
        XCTAssertEqual(resultURL.path, existingFile.path)
    }
    
    func test_storeModelInDocuments_movesFromTmpWhenPreferMoveTrue() throws {
        let tmpSubdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmp")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: tmpSubdir, withIntermediateDirectories: true)
        
        let tmpFile = tmpSubdir.appendingPathComponent("model.mlmodel")
        try "content".write(to: tmpFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: tmpFile,
            configurationId: testConfigurationId,
            preferMove: true
        )
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        
        try? FileManager.default.removeItem(at: tmpSubdir)
    }
    
    func test_storeModelInDocuments_copiesFromTmpWhenPreferMoveFalse() throws {
        let tmpSubdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmp")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: tmpSubdir, withIntermediateDirectories: true)
        
        let tmpFile = tmpSubdir.appendingPathComponent("model.mlmodel")
        try "content".write(to: tmpFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: tmpFile,
            configurationId: testConfigurationId,
            preferMove: false
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        
        try? FileManager.default.removeItem(at: tmpSubdir)
    }
    
    func test_storeModelInDocuments_copiesNonTmpFileEvenWithPreferMoveTrue() throws {
        // Create a directory under Library (not tmp/Caches) to test non-temporary file behavior
        guard let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            XCTFail("Could not access Library directory")
            return
        }
        
        let nonTmpDir = libraryDir
            .appendingPathComponent("FileManagerTests")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: nonTmpDir, withIntermediateDirectories: true)
        
        let sourceFile = nonTmpDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: sourceFile,
            configurationId: testConfigurationId,
            preferMove: true
        )
        
        // Source should still exist (non-tmp/non-Caches files are always copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        
        // Cleanup
        try? FileManager.default.removeItem(at: nonTmpDir)
    }
    
    func test_storeModelInDocuments_movesFromCachesWhenPreferMoveTrue() throws {
        let cachesSubdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caches")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: cachesSubdir, withIntermediateDirectories: true)
        
        let cachesFile = cachesSubdir.appendingPathComponent("model.mlmodel")
        try "content".write(to: cachesFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: cachesFile,
            configurationId: testConfigurationId,
            preferMove: true
        )
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        
        try? FileManager.default.removeItem(at: cachesSubdir)
    }
}

// MARK: - ModelFileStorageError Tests

final class ModelFileStorageErrorTests: XCTestCase {
    
    func test_cannotCreateTargetDirectory_hasErrorDescription() {
        let error = ModelFileStorageError.cannotCreateTargetDirectory
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
    
    func test_cannotAccessDocuments_hasErrorDescription() {
        let error = ModelFileStorageError.cannotAccessDocuments
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
    
    func test_fileOperationFailed_hasErrorDescription() {
        let error = ModelFileStorageError.fileOperationFailed
        
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
    
    func test_errorDescriptions_areDistinct() {
        let errors: [ModelFileStorageError] = [
            .cannotCreateTargetDirectory,
            .cannotAccessDocuments,
            .fileOperationFailed
        ]
        
        let descriptions = errors.compactMap { $0.errorDescription }
        let uniqueDescriptions = Set(descriptions)
        
        XCTAssertEqual(descriptions.count, uniqueDescriptions.count)
    }
    
    func test_errorConformsToLocalizedError() {
        let error: LocalizedError = ModelFileStorageError.cannotCreateTargetDirectory
        
        XCTAssertNotNil(error.errorDescription)
    }
}
