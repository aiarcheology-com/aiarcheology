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
        // The real Caches directory (AIA-0963); a `Caches` component elsewhere no longer counts.
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            XCTFail("Could not access Caches directory")
            return
        }
        let cachesSubdir = cachesDir
            .appendingPathComponent("FileManagerTests")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: cachesSubdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cachesSubdir) }
        
        let cachesFile = cachesSubdir.appendingPathComponent("model.mlmodel")
        try "content".write(to: cachesFile, atomically: true, encoding: .utf8)
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: cachesFile,
            configurationId: testConfigurationId,
            preferMove: true
        )
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

    }
    
    // MARK: - storeModelInDocuments containment (AIA-0963)
    
    /// A directory beside Documents whose name merely starts with "Documents". A bare path prefix
    /// treats it as already stored and returns it unchanged instead of copying it.
    func test_storeModelInDocuments_copiesFromDocumentsSiblingDirectory() throws {
        let documentsDir = try XCTUnwrap(FileManager.default.documentDirectory)
        let siblingDir = documentsDir.deletingLastPathComponent()
            .appendingPathComponent(documentsDir.lastPathComponent + "Backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: siblingDir) }
        let sourceFile = siblingDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let resultURL = try FileManager.storeModelInDocuments(
            from: sourceFile,
            configurationId: testConfigurationId
        )
        
        let configDir = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: testConfigurationId))
        XCTAssertNotEqual(resultURL.path, sourceFile.path)
        XCTAssertEqual(resultURL.deletingLastPathComponent().pathComponents, configDir.pathComponents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        XCTAssertNoThrow(try resultURL.relativePath(from: .documentDirectory))
    }
    
    func test_storeModelInDocuments_rejectsDocumentsDirectoryItself() throws {
        let documentsDir = try XCTUnwrap(FileManager.default.documentDirectory)
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(from: documentsDir, configurationId: testConfigurationId)
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
    }
    
    /// `Configurations/<id>/../<id>/model` names the copy target itself, which is deleted before the
    /// copy. It must be rejected, and the model must survive.
    func test_storeModelInDocuments_rejectsDotDotPathAndKeepsTheFile() throws {
        // Stored under *another* configuration, so the copy target is a different file and only the
        // explicit `.`/`..` rejection, not the same-file guard, can stop this.
        let otherID = UUID()
        let configDir = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: otherID))
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let storedFile = configDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: storedFile, atomically: true, encoding: .utf8)
        let escapingURL = configDir
            .appendingPathComponent("..")
            .appendingPathComponent(otherID.uuidString)
            .appendingPathComponent("model.mlmodel")
        XCTAssertTrue(escapingURL.pathComponents.contains(".."), "fixture must keep its `..` component")
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(from: escapingURL, configurationId: testConfigurationId)
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedFile.path))
    }
    
    /// The stored model reached through a path no lexical check recognises (here a symlinked
    /// directory; on device, a `/private` alias). Storing it would delete the target, which is the
    /// source, before copying it.
    func test_storeModelInDocuments_rejectsAliasOfTheTargetAndKeepsTheFile() throws {
        let configDir = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: testConfigurationId))
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let storedFile = configDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: storedFile, atomically: true, encoding: .utf8)
        let alias = testDirectory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: configDir)
        let aliasedFile = alias.appendingPathComponent("model.mlmodel")
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(from: aliasedFile, configurationId: testConfigurationId)
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        XCTAssertEqual(try String(contentsOf: storedFile, encoding: .utf8), "content")
    }
    
    /// The source is a symlink *file* pointing at the stored model. Resource values describe the
    /// link itself, so identity must be read after resolving it.
    func test_storeModelInDocuments_rejectsSymlinkToTheTargetAndKeepsTheFile() throws {
        let configDir = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: testConfigurationId))
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let storedFile = configDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: storedFile, atomically: true, encoding: .utf8)
        let link = testDirectory.appendingPathComponent("model.mlmodel")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storedFile)
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(from: link, configurationId: testConfigurationId)
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        XCTAssertEqual(try String(contentsOf: storedFile, encoding: .utf8), "content")
    }
    
    /// A user location whose path merely contains `/tmp/` is not a temporary file. Moving it would
    /// remove the user's file from where they keep it.
    func test_storeModelInDocuments_copiesNonTemporaryPathContainingTmpEvenWithPreferMoveTrue() throws {
        let libraryDir = try XCTUnwrap(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        let fakeTmpRoot = libraryDir
            .appendingPathComponent("FileManagerTests")
            .appendingPathComponent(UUID().uuidString)
        let fakeTmpDir = fakeTmpRoot.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: fakeTmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeTmpRoot) }
        let sourceFile = fakeTmpDir.appendingPathComponent("model.mlmodel")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(sourceFile.path.contains("/tmp/"), "fixture must contain the substring the old check matched")
        
        let destinationURL = try FileManager.storeModelInDocuments(
            from: sourceFile,
            configurationId: testConfigurationId,
            preferMove: true
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }
    
    // MARK: - Replacing an existing model (AIA-0967)
    
    /// A fixture `Container/Documents` under this test's temporary directory, so these tests never
    /// store into, or copy, the real app container.
    private func makeFixtureContainer() throws -> (container: URL, documents: URL) {
        let container = testDirectory.appendingPathComponent("Container")
        let documents = container.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return (container, documents)
    }
    
    /// Writes `content` as an installed model named `name` under the fixture Documents.
    private func installExistingModel(named name: String, content: String, in documents: URL) throws -> URL {
        let configDir = FileManager.configurationDirectory(id: testConfigurationId, in: documents)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let target = configDir.appendingPathComponent(name)
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
    
    private func configDirectoryListing(in documents: URL) throws -> [String] {
        let configDir = FileManager.configurationDirectory(id: testConfigurationId, in: documents)
        return try FileManager.default.contentsOfDirectory(atPath: configDir.path).sorted()
    }
    
    /// A re-download whose move fails (here the staged package has vanished) must leave the model
    /// that was installed before it. Deleting the target first would lose it.
    func test_moveModelToDocuments_keepsExistingModelWhenReplacementFails() throws {
        let (_, documents) = try makeFixtureContainer()
        let existing = try installExistingModel(named: "model.mlmodel", content: "installed", in: documents)
        let missingSource = testDirectory.appendingPathComponent("model.mlmodel")
        
        XCTAssertThrowsError(
            try FileManager.moveModelToDocuments(
                from: missingSource,
                configurationId: testConfigurationId,
                documentsURL: documents
            )
        )
        
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "installed")
        XCTAssertEqual(try configDirectoryListing(in: documents), ["model.mlmodel"])
    }
    
    func test_copyModelToDocuments_keepsExistingModelWhenReplacementFails() throws {
        let (_, documents) = try makeFixtureContainer()
        let existing = try installExistingModel(named: "model.mlmodel", content: "installed", in: documents)
        let missingSource = testDirectory.appendingPathComponent("model.mlmodel")
        
        XCTAssertThrowsError(
            try FileManager.copyModelToDocuments(
                from: missingSource,
                configurationId: testConfigurationId,
                documentsURL: documents
            )
        )
        
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "installed")
        XCTAssertEqual(try configDirectoryListing(in: documents), ["model.mlmodel"])
    }
    
    /// A catalog package is a directory: the new package replaces the installed one, and no staged
    /// item is left beside it.
    func test_moveModelToDocuments_replacesExistingPackageAndLeavesNoStagedItem() throws {
        let (_, documents) = try makeFixtureContainer()
        let configDir = FileManager.configurationDirectory(id: testConfigurationId, in: documents)
        let installedPackage = configDir.appendingPathComponent("model.mlpackage")
        try FileManager.default.createDirectory(at: installedPackage, withIntermediateDirectories: true)
        try "installed".write(to: installedPackage.appendingPathComponent("weights"), atomically: true, encoding: .utf8)
        try "stale".write(to: installedPackage.appendingPathComponent("only-in-old"), atomically: true, encoding: .utf8)
        let newPackage = testDirectory.appendingPathComponent("staging").appendingPathComponent("model.mlpackage")
        try FileManager.default.createDirectory(at: newPackage, withIntermediateDirectories: true)
        try "downloaded".write(to: newPackage.appendingPathComponent("weights"), atomically: true, encoding: .utf8)
        
        let result = try FileManager.moveModelToDocuments(
            from: newPackage,
            configurationId: testConfigurationId,
            documentsURL: documents
        )
        
        XCTAssertEqual(result.pathComponents, installedPackage.pathComponents)
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("weights"), encoding: .utf8), "downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("only-in-old").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPackage.path))
        XCTAssertEqual(try configDirectoryListing(in: documents), ["model.mlpackage"])
    }
    
    func test_copyModelToDocuments_replacesExistingFileAndLeavesNoStagedItem() throws {
        let (_, documents) = try makeFixtureContainer()
        _ = try installExistingModel(named: "model.mlmodel", content: "installed", in: documents)
        let source = testDirectory.appendingPathComponent("model.mlmodel")
        try "picked".write(to: source, atomically: true, encoding: .utf8)
        
        let result = try FileManager.copyModelToDocuments(
            from: source,
            configurationId: testConfigurationId,
            documentsURL: documents
        )
        
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "picked")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "picked")
        XCTAssertEqual(try configDirectoryListing(in: documents), ["model.mlmodel"])
    }
    
    /// A staged item left by a crash between staging and swapping is swept by the next install of
    /// the same name. Nothing else would ever remove it.
    func test_moveModelToDocuments_removesStagedItemLeftByAnEarlierInstall() throws {
        let (_, documents) = try makeFixtureContainer()
        _ = try installExistingModel(named: "model.mlmodel", content: "installed", in: documents)
        let configDir = FileManager.configurationDirectory(id: testConfigurationId, in: documents)
        let leftover = configDir.appendingPathComponent(".model.mlmodel.staging-\(UUID().uuidString)")
        try "orphan".write(to: leftover, atomically: true, encoding: .utf8)
        let unrelated = configDir.appendingPathComponent(".other.mlmodel.staging-\(UUID().uuidString)")
        try "someone else's".write(to: unrelated, atomically: true, encoding: .utf8)
        let source = testDirectory.appendingPathComponent("model.mlmodel")
        try "downloaded".write(to: source, atomically: true, encoding: .utf8)
        
        let result = try FileManager.moveModelToDocuments(
            from: source,
            configurationId: testConfigurationId,
            documentsURL: documents
        )
        
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "downloaded")
        XCTAssertEqual(try configDirectoryListing(in: documents), [unrelated.lastPathComponent, "model.mlmodel"].sorted())
    }
    
    // MARK: - A source that contains its target (AIA-0968)
    
    /// A tiny fixture container: a parent of Documents with one file beside it. If the guard were
    /// missing, the copy of this tree into its own descendant is what a test would start, so it has
    /// to stay small.
    private func makeFixtureContainerWithContent() throws -> (container: URL, documents: URL) {
        let fixture = try makeFixtureContainer()
        let library = fixture.container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "prefs".write(to: library.appendingPathComponent("prefs.plist"), atomically: true, encoding: .utf8)
        return fixture
    }
    
    private func assertNothingChanged(in container: URL, documents: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let fileManager = FileManager.default
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: container.path).sorted(), ["Documents", "Library"], file: file, line: line)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: documents.path), [], file: file, line: line)
        XCTAssertEqual(
            try String(contentsOf: container.appendingPathComponent("Library/prefs.plist"), encoding: .utf8),
            "prefs",
            file: file,
            line: line
        )
    }
    
    func test_storeModelInDocuments_rejectsAncestorOfDocumentsAndCreatesNothing() throws {
        let (container, documents) = try makeFixtureContainerWithContent()
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(
                from: container,
                configurationId: testConfigurationId,
                documentsURL: documents
            )
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        try assertNothingChanged(in: container, documents: documents)
    }
    
    /// `Downloader` calls `moveModelToDocuments` directly, bypassing `storeModelInDocuments`.
    func test_moveModelToDocuments_rejectsAncestorOfDocumentsAndCreatesNothing() throws {
        let (container, documents) = try makeFixtureContainerWithContent()
        
        XCTAssertThrowsError(
            try FileManager.moveModelToDocuments(
                from: container,
                configurationId: testConfigurationId,
                documentsURL: documents
            )
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        try assertNothingChanged(in: container, documents: documents)
    }
    
    /// The container reached through a symlink passes the lexical containment test; filesystem
    /// identity of the target's ancestors still recognises it.
    func test_storeModelInDocuments_rejectsAliasOfAncestorOfDocuments() throws {
        let (container, documents) = try makeFixtureContainerWithContent()
        let alias = testDirectory.appendingPathComponent("ContainerAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: container)
        XCTAssertFalse(documents.isStrictlyContained(in: alias), "fixture must defeat the lexical check")
        
        XCTAssertThrowsError(
            try FileManager.storeModelInDocuments(
                from: alias,
                configurationId: testConfigurationId,
                documentsURL: documents
            )
        ) { error in
            XCTAssertEqual(error as? ModelFileStorageError, .fileOperationFailed)
        }
        try assertNothingChanged(in: container, documents: documents)
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
