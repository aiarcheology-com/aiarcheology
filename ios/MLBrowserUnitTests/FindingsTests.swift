//
//  FindingsTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import XCTest
import CoreData
import UIKit
@testable import ML_Browser

// MARK: - Validation & lifecycle

@MainActor
final class FindingValidationTests: XCTestCase {
    var stack: TestCoreDataStack!
    var moc: NSManagedObjectContext { stack.viewContext }

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private func makeValidFinding() -> Finding {
        let finding = Finding.create(in: moc)
        finding.creationDate_ = .now
        finding.page = URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
        finding.screenshotFilename = Finding.screenshotFilename(for: finding.entityId)
        finding.boxX = 0.25
        finding.boxY = 0.25
        finding.boxWidth = 0.5
        finding.boxHeight = 0.5
        finding.detectionClass = "fortification"
        finding.detectionConfidence = 0.9
        return finding
    }

    func testValidFinding_TransitionsToReadyAndSaves() throws {
        let finding = makeValidFinding()
        finding.transition(to: .draft)
        XCTAssertTrue(finding.validationReport().isValid)
        finding.transition(to: .ready)
        XCTAssertEqual(finding.lifeCycle, .ready)
        try Finding.save(in: moc)
        XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1)
    }

    func testBoxOutsideUnitRect_FailsValidation() {
        let finding = makeValidFinding()
        finding.boxX = 0.8
        finding.boxWidth = 0.5 // maxX = 1.3
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    func testNonFiniteBox_FailsValidation() {
        let finding = makeValidFinding()
        finding.boxY = .nan
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    func testZeroSizeBox_FailsValidation() {
        let finding = makeValidFinding()
        finding.boxWidth = 0
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    func testFileURLPage_FailsValidation() {
        let finding = makeValidFinding()
        finding.page = URL(fileURLWithPath: "/tmp/page.html")
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    func testConfidenceOutOfRange_FailsValidation() {
        let finding = makeValidFinding()
        finding.detectionConfidence = 1.5
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    func testMismatchedScreenshotFilename_FailsValidation() {
        let finding = makeValidFinding()
        finding.screenshotFilename = "\(UUID().uuidString).png"
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
    }

    /// The save-sheet failure path: an invalid finding at .ready makes the context
    /// save throw, and deleting the pending object must leave nothing behind for a
    /// later unrelated save to commit.
    func testFailedSave_DeletingPendingObjectLeavesContextClean() {
        let finding = makeValidFinding()
        finding.boxWidth = 2 // invalid
        finding.transition(to: .draft)
        finding.lifeCycle = .ready // force past the guarded transition, as a corrupt write would

        XCTAssertThrowsError(try Finding.save(in: moc))

        Finding.delete(finding, in: moc)
        XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0)
        XCTAssertNoThrow(try Finding.save(in: moc))
    }
}

// MARK: - Label suggestions

@MainActor
final class FindingLabelTests: XCTestCase {
    var stack: TestCoreDataStack!
    var moc: NSManagedObjectContext { stack.viewContext }

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private func insertFinding(label: String?) throws {
        let finding = Finding.create(in: moc)
        finding.creationDate_ = .now
        finding.page = URL(string: "https://example.com/map")
        finding.screenshotFilename = Finding.screenshotFilename(for: finding.entityId)
        finding.boxX = 0.1
        finding.boxY = 0.1
        finding.boxWidth = 0.2
        finding.boxHeight = 0.2
        finding.detectionConfidence = 0.5
        finding.label_ = label
        finding.transition(to: .draft)
        finding.transition(to: .ready)
        try Finding.save(in: moc)
    }

    func testDistinctLabels_DedupesTrimsAndSorts() throws {
        try insertFinding(label: "fortification")
        try insertFinding(label: "fields")
        try insertFinding(label: "fields")
        try insertFinding(label: "  fields  ")
        try insertFinding(label: "   ")
        try insertFinding(label: nil)

        XCTAssertEqual(Finding.distinctLabels(in: moc), ["fields", "fortification"])
    }

    func testLabelSuggestions_DetectionClassFirst_UnionCaseInsensitive() throws {
        try insertFinding(label: "castle")
        try insertFinding(label: "Fortification")

        let suggestions = SaveFindingSheet.labelSuggestions(detectionClass: "fortification", in: moc)

        // The class leads; the stored label differing only in case is dropped.
        XCTAssertEqual(suggestions, ["fortification", "castle"])
    }

    func testLabelSuggestions_NoClass_UsesStoredLabelsOnly() throws {
        try insertFinding(label: "castle")

        XCTAssertEqual(SaveFindingSheet.labelSuggestions(detectionClass: nil, in: moc), ["castle"])
    }
}

// MARK: - Coordinate transform & crop

final class VisionRectTransformTests: XCTestCase {
    func testVisionRect_OffCenterBox_FlipsY() {
        // Vision box near the TOP of the image (high Y in bottom-left coords)
        let box = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)
        let rect = box.visionRect(in: CGSize(width: 1000, height: 500))

        XCTAssertEqual(rect.minX, 100, accuracy: 0.001)
        // maxY = 0.9 → top-left y = (1 − 0.9) · 500 = 50 (near the top, as expected)
        XCTAssertEqual(rect.minY, 50, accuracy: 0.001)
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 150, accuracy: 0.001)
    }

    func testManualBox_CenterTap_FlipsYAndCenters() {
        // Tap near the TOP of a 1000×500 view → high Vision Y.
        let box = FindingCapture.manualBox(at: CGPoint(x: 500, y: 50), in: CGSize(width: 1000, height: 500), side: 64)

        XCTAssertEqual(box.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(box.midY, 0.9, accuracy: 0.001) // 1 − 50/500
        XCTAssertEqual(box.width, 0.064, accuracy: 0.001)
        XCTAssertEqual(box.height, 0.128, accuracy: 0.001)
    }

    func testManualBox_CornerTap_StaysInsideUnitRect() {
        let size = CGSize(width: 400, height: 800)
        for corner in [CGPoint.zero, CGPoint(x: 400, y: 0), CGPoint(x: 0, y: 800), CGPoint(x: 400, y: 800)] {
            let box = FindingCapture.manualBox(at: corner, in: size)
            XCTAssertGreaterThanOrEqual(box.minX, 0)
            XCTAssertGreaterThanOrEqual(box.minY, 0)
            XCTAssertLessThanOrEqual(box.maxX, 1)
            XCTAssertLessThanOrEqual(box.maxY, 1)
            XCTAssertGreaterThan(box.width, 0)
            XCTAssertGreaterThan(box.height, 0)
        }
    }

    func testVisionRect_FullFrame_IsIdentity() {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1).visionRect(in: CGSize(width: 640, height: 480))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    /// End-to-end crop: stored PNG → cgImage-dimension pixel rect → cropped thumbnail.
    @MainActor
    func testCropThumbnail_CropsExpectedPixelRegion() throws {
        let stack = TestCoreDataStack()
        let moc = stack.viewContext

        let imageSize = CGSize(width: 200, height: 100)
        let image = UIGraphicsImageRenderer(size: imageSize).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }

        let finding = Finding.create(in: moc)
        finding.creationDate_ = .now
        finding.page = URL(string: "https://example.com")
        finding.boxX = 0.25
        finding.boxY = 0.25
        finding.boxWidth = 0.5
        finding.boxHeight = 0.5
        finding.detectionConfidence = 0.5
        finding.screenshotFilename = try FindingScreenshotStore.save(image, for: finding.entityId)
        defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

        let thumbnail = try XCTUnwrap(finding.cropThumbnail())
        let cgImage = try XCTUnwrap(thumbnail.cgImage)
        let storedCG = try XCTUnwrap(FindingScreenshotStore.load(filename: finding.screenshotFilename)?.cgImage)

        // Half the stored image in each dimension, independent of UIImage.scale.
        XCTAssertEqual(cgImage.width, storedCG.width / 2)
        XCTAssertEqual(cgImage.height, storedCG.height / 2)
    }
}

// MARK: - Orphan sweep

@MainActor
final class FindingScreenshotStoreTests: XCTestCase {
    func testSweepOrphans_RemovesFileWithoutRow_KeepsReferencedFile() throws {
        let stack = TestCoreDataStack()
        let moc = stack.viewContext

        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }

        // Referenced file: row exists.
        let finding = Finding.create(in: moc)
        finding.creationDate_ = .now
        finding.page = URL(string: "https://example.com")
        finding.boxX = 0.1
        finding.boxY = 0.1
        finding.boxWidth = 0.5
        finding.boxHeight = 0.5
        finding.detectionConfidence = 0.5
        finding.screenshotFilename = try FindingScreenshotStore.save(image, for: finding.entityId)
        finding.transition(to: .draft)
        finding.transition(to: .ready)
        try Finding.save(in: moc)
        defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

        // Orphan: file with no row (a save whose entity insert failed mid-flight).
        let orphanId = UUID()
        let orphanFilename = try FindingScreenshotStore.save(image, for: orphanId)
        let orphanURL = try XCTUnwrap(FindingScreenshotStore.url(forFilename: orphanFilename))

        FindingScreenshotStore.sweepOrphans(in: moc)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        let keptURL = try XCTUnwrap(FindingScreenshotStore.url(forFilename: Finding.screenshotFilename(for: finding.entityId)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
    }
}

// MARK: - Capture pause/resume (Guide)

@MainActor
final class FindingCaptureGuideTests: XCTestCase {
    var settings: Settings!
    var snapState: SnapState!
    var sut: Guide!
    private var dataController: DataController!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        dataController = DataController(inMemory: true)
        snapState = SnapState(settings: settings)
        sut = Guide(
            snap: snapState,
            deep: DeepState(dataController: dataController),
            settings: settings,
            dataController: dataController,
            demoDataManager: DemoDataManager(dataController: dataController),
            snapAdjustment: SnapAdjustment()
        )
    }

    override func tearDown() async throws {
        snapState.stopTimer()
        sut = nil
        snapState = nil
        dataController = nil
        settings = nil
        try await super.tearDown()
    }

    func testCaptureStarted_StopsTimer_AndEndedResumes() {
        sut.ontheflyDetectionTapped()
        XCTAssertNotNil(snapState.timerCancellable)

        sut.findingCaptureStarted()
        XCTAssertNil(snapState.timerCancellable)

        sut.findingCaptureEnded()
        XCTAssertNotNil(snapState.timerCancellable)
    }

    func testCaptureEnded_DoesNotResume_WhenDetectionWasOff() {
        XCTAssertNil(snapState.timerCancellable)

        sut.findingCaptureStarted()
        sut.findingCaptureEnded()

        XCTAssertNil(snapState.timerCancellable)
    }

    func testCaptureEnded_DoesNotResume_WhenDetectionDisabledMeanwhile() {
        sut.ontheflyDetectionTapped()
        sut.findingCaptureStarted()
        // Background auto-pause while the sheet is up turns detection off.
        sut.ontheflyDetectionTapped()

        sut.findingCaptureEnded()

        XCTAssertNil(snapState.timerCancellable)
    }
}

// MARK: - Migration gate (plan §1)

/// Opens a store created with the RELEASED model (0.0.0) using the current model
/// under production-equivalent options: automatic migration ON, mapping-model
/// inference OFF (DataController disables inference for App Store and Debug
/// builds, so the bundled explicit mapping carries the release path). Every row
/// must survive and `FillEntityIdIfNilPolicy` must fill missing entityIds.
///
/// Deliberately NOT DataController(storeURL:): that initializer forces inference
/// ON, and the app's recovery path destroys failing stores — both would turn a
/// broken mapping into a false pass.
final class FindingMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTest-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        if let url = storeURL {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        storeURL = nil
        super.tearDown()
    }

    private func momdURL() throws -> URL {
        let url = Bundle.main.url(forResource: "MLBrowser", withExtension: "momd")
            ?? Bundle.allBundles.compactMap { $0.url(forResource: "MLBrowser", withExtension: "momd") }.first
        return try XCTUnwrap(url, "Compiled model bundle not found")
    }

    func testMigrationFromReleasedModel_PreservesRowsAndFillsEntityIds() throws {
        // 1. Seed a store with the released 0.0.0 model (version file "MLBrowser.mom").
        let sourceModelURL = try momdURL().appendingPathComponent("MLBrowser.mom")
        let sourceModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: sourceModelURL))
        // The app's NSManagedObject subclasses match the CURRENT schema; their
        // awakeFromInsert would touch attributes the 0.0.0 entity doesn't have
        // (unrecognized selector). Seed with plain NSManagedObject instead.
        for entity in sourceModel.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }

        let seedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
        try seedCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let seedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        seedContext.persistentStoreCoordinator = seedCoordinator

        var seeded = 0
        seedContext.performAndWait {
            for index in 0..<3 {
                let entry = NSManagedObject(
                    entity: sourceModel.entitiesByName["WebHistoryEntry"]!,
                    insertInto: seedContext
                )
                entry.setValue(URL(string: "https://example.com/\(index)"), forKey: "page")
                entry.setValue(Date(), forKey: "creationDate_")
            }
            try? seedContext.save()
            seeded = 3
        }
        XCTAssertEqual(seeded, 3)
        for store in seedCoordinator.persistentStores {
            try seedCoordinator.remove(store)
        }

        // 2. Reopen with the CURRENT model under production-equivalent options.
        let currentModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: momdURL()))
        let container = NSPersistentContainer(name: "MigrationTest", managedObjectModel: currentModel)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = false // production behavior
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        XCTAssertNil(
            loadError,
            """
            Migration from the released 0.0.0 store failed: \(String(describing: loadError)). \
            If the 0.0.1 model changed, the 0.0.0→0.0.1 mapping model must be \
            recreated in Xcode (its xcmapping embeds both models).
            """
        )
        guard loadError == nil else { return }

        // 3. Every seeded row survived and the policy filled entityIds.
        let context = container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "WebHistoryEntry")
        let migrated = try context.fetch(request)
        XCTAssertEqual(migrated.count, 3)
        for row in migrated {
            XCTAssertNotNil(row.value(forKey: "entityId"), "FillEntityIdIfNilPolicy did not fill entityId")
        }

        // 4. The new Finding entity is usable in the migrated store.
        XCTAssertNotNil(container.managedObjectModel.entitiesByName["Finding"])
    }
}
