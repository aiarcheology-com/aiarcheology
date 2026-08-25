//
//  FindingsTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import XCTest
@preconcurrency import CoreData
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
        finding.title = "Test Finding"
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

    func testMissingTitle_FailsValidation() {
        let finding = makeValidFinding()
        finding.title = "   " // whitespace-only is treated as empty
        finding.transition(to: .draft)
        XCTAssertFalse(finding.validationReport().isValid)
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

    func testMissingScreenshotFilename_FailsValidation() {
        let finding = makeValidFinding()
        finding.screenshotFilename = nil
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
        finding.title = "Test Finding"
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
        // Case variants are ONE chip (first-seen casing wins) — the list filter
        // is case-insensitive too.
        try insertFinding(label: "Fields")
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

// MARK: - Crop math

final class FindingCropMathTests: XCTestCase {
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let fitted = CGSize(width: 400, height: 200)

    private func visionRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Mirrors Finding's strict persistence invariant, including `min + size <= 1`.
    private func assertStrictUnitRect(_ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, 1, file: file, line: line)
    }

    // cover == fitted models an image whose aspect already matches the viewport,
    // so the cover formula reduces to the simple zoom/pan case.
    func testCropRect_ScaleOne_CoverMatchesViewport_IsUnitRect() {
        XCTAssertEqual(FindingCapture.cropRect(scale: 1, offset: .zero, fitted: fitted, cover: fitted), unit)
    }

    func testCropRect_ZoomTwoCentered_IsCenterQuarter() {
        let crop = FindingCapture.cropRect(scale: 2, offset: .zero, fitted: fitted, cover: fitted)
        XCTAssertEqual(crop.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 0.25, accuracy: 0.001)
        XCTAssertEqual(crop.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(crop.height, 0.5, accuracy: 0.001)
    }

    func testCropRect_PanMovesWindowOpposite_AndClamps() {
        // Image dragged fully right at 2×: the window reaches the LEFT edge.
        let maxOffset = CGSize(width: fitted.width * (2 - 1) / 2, height: 0)
        let crop = FindingCapture.cropRect(scale: 2, offset: maxOffset, fitted: fitted, cover: fitted)
        XCTAssertEqual(crop.minX, 0, accuracy: 0.001)
        // Excessive offsets clamp instead of leaving the image.
        let over = FindingCapture.cropRect(scale: 2, offset: CGSize(width: 10_000, height: -10_000), fitted: fitted, cover: fitted)
        XCTAssertEqual(over.minX, 0, accuracy: 0.001)
        XCTAssertEqual(over.maxY, 1, accuracy: 0.001)
    }

    func testCropRect_CoverOverflowAxis_ScaleOne_CropsOverflowCentered() {
        // Covered image is twice as tall as the viewport: at scale 1 the window is
        // full width but only the centered middle of the height (no letterbox).
        let cover = CGSize(width: 400, height: 800)
        let crop = FindingCapture.cropRect(scale: 1, offset: .zero, fitted: fitted, cover: cover)
        XCTAssertEqual(crop.width, 1, accuracy: 0.001)
        XCTAssertEqual(crop.height, 0.25, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 0.375, accuracy: 0.001)
    }

    func testRemappedBox_InsideCrop_RenormalizesWithYFlip() {
        // Crop = top-left quadrant (top-left coords). A Vision box in the image's
        // upper-left area: vision y 0.5...0.75 → top-left y 0.25...0.5.
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let visionBox = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.25)

        let remapped = FindingCapture.remappedBox(visionBox, into: crop)

        XCTAssertEqual(remapped.minX, 0.2, accuracy: 0.001)   // 0.1 / 0.5
        XCTAssertEqual(remapped.width, 0.4, accuracy: 0.001)  // 0.2 / 0.5
        XCTAssertEqual(remapped.height, 0.5, accuracy: 0.001) // 0.25 / 0.5
        // top-left y 0.25/0.5 = 0.5, height 0.5 → vision y = 1 − 0.5 − 0.5 = 0.
        XCTAssertEqual(remapped.minY, 0, accuracy: 0.001)
    }

    func testRemappedBox_OutsideCrop_FallsBackToWholeCrop() {
        let crop = CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
        let visionBox = CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(FindingCapture.remappedBox(visionBox, into: crop), unit)
    }

    func testRemappedBox_NoCrop_IsUnchanged() {
        let visionBox = CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.2)
        XCTAssertEqual(FindingCapture.remappedBox(visionBox, into: unit), visionBox)
    }

    func testRemappedBox_EdgeTouchingAndClippedBoxes_StayInsideUnitRect() {
        // This deliberately non-binary crop produced a one-ulp y underflow and x overflow
        // with the former origin-plus-size normalization.
        let crop = CGRect(x: 0.053, y: 0.053, width: 0.211, height: 0.211)
        let side = crop.width / 3
        let centered = CGPoint(x: crop.midX - side / 2, y: crop.midY - side / 2)
        let topLeftBoxes = [
            CGRect(x: crop.minX, y: centered.y, width: side, height: side),
            CGRect(x: crop.maxX - side, y: centered.y, width: side, height: side),
            CGRect(x: centered.x, y: crop.minY, width: side, height: side),
            CGRect(x: centered.x, y: crop.maxY - side, width: side, height: side),
            CGRect(x: crop.minX - side / 2, y: centered.y, width: side, height: side),
            CGRect(x: crop.maxX - side / 2, y: centered.y, width: side, height: side),
            CGRect(x: centered.x, y: crop.minY - side / 2, width: side, height: side),
            CGRect(x: centered.x, y: crop.maxY - side / 2, width: side, height: side),
            CGRect(x: crop.maxX - side, y: crop.maxY - side, width: side, height: side)
        ]

        for topLeftBox in topLeftBoxes {
            assertStrictUnitRect(FindingCapture.remappedBox(visionRect(fromTopLeft: topLeftBox), into: crop))
        }
    }

    func testRemappedBox_NearDegenerateCrop_StaysInsideUnitRect() {
        let crop = CGRect(x: 0.123_456, y: 0.654_321, width: 0.000_001, height: 0.000_001)
        let side = crop.width / 3
        let topLeftBox = CGRect(
            x: crop.maxX - side,
            y: crop.maxY - side,
            width: side,
            height: side
        )

        assertStrictUnitRect(FindingCapture.remappedBox(visionRect(fromTopLeft: topLeftBox), into: crop))
    }
}

// MARK: - Pick-mode detection hit test

final class FindingPickHitTestTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 1000)

    private func observation(_ box: CGRect) -> DetectedObject {
        DetectedObject(uuid: UUID(), labels: [], confidence: 0.5, boundingBox: box, regionIndex: 0)
    }

    private func results(_ boxes: [CGRect]) -> [DetectionResult] {
        [(observations: boxes.map(observation), params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"))]
    }

    func testTapInsideBox_ReturnsIt() {
        // Vision box (0.2, 0.2, 0.4, 0.4) → view rect (200, 400, 400, 400).
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let hit = FindingCapture.detection(at: CGPoint(x: 400, y: 600), in: size, results: results([box]))
        XCTAssertEqual(hit?.observation.boundingBox, box)
    }

    func testNestedBoxes_SmallestWins() {
        let outer = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let inner = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        // Center of the view is inside both.
        let hit = FindingCapture.detection(at: CGPoint(x: 500, y: 500), in: size, results: results([outer, inner]))
        XCTAssertEqual(hit?.observation.boundingBox, inner)
    }

    func testTinyBox_PickableWithinMinimumTarget() {
        // 10×10pt box centered at (500, 500); the tap is 15pt off — outside the
        // exact rect but inside the 44pt minimum target.
        let tiny = CGRect(x: 0.495, y: 0.495, width: 0.01, height: 0.01)
        let hit = FindingCapture.detection(at: CGPoint(x: 515, y: 500), in: size, results: results([tiny]))
        XCTAssertEqual(hit?.observation.boundingBox, tiny)
    }

    func testTapOutsideAllBoxes_ReturnsNil() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        XCTAssertNil(FindingCapture.detection(at: CGPoint(x: 950, y: 50), in: size, results: results([box])))
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
        finding.title = "Test Finding"
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

// MARK: - Capture pause/resume (DetectionSessionState)

@MainActor
final class FindingCaptureDetectionTests: XCTestCase {
    var settings: Settings!
    var snapState: SnapState!
    // `DetectionSessionState.snapAdjustment` is `unowned`; hold it strong for the whole test.
    private var snapAdjustment: SnapAdjustment!
    var sut: DetectionSessionState!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        snapState = SnapState(settings: settings)
        snapAdjustment = SnapAdjustment()
        sut = DetectionSessionState(
            snap: snapState,
            settings: settings,
            snapAdjustment: snapAdjustment
        )
    }

    override func tearDown() async throws {
        snapState.stopTimer()
        sut = nil
        snapAdjustment = nil
        snapState = nil
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

/// Opens a store created with an OLDER model version using the current model
/// (0.0.2) under production-equivalent options: automatic migration ON,
/// mapping-model inference OFF (DataController disables inference for App Store
/// and Debug builds, so the bundled explicit mapping carries the release path).
/// Every row must survive and `FillEntityIdIfNilPolicy` must fill missing entityIds.
///
/// Core Data migration is SINGLE-HOP: it looks for one mapping model straight
/// from the store's own source model to the current one, never chaining through
/// the intermediate versions. So every model version still in the field needs its
/// own mapping to 0.0.2, and both now exist — `0.0.0→0.0.2` (an install that never
/// upgraded) and `0.0.1→0.0.2` (one that did). One test per live source model.
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

        // Seed every entity the FillEntityIdIfNilPolicy migrates.
        let seededEntities = ["WebHistoryEntry", "DeepConfiguration", "DownloadItem"]
        try seedContext.performAndWait {
            for entityName in seededEntities {
                for index in 0..<3 {
                    let entity = sourceModel.entitiesByName[entityName]!
                    let row = NSManagedObject(entity: entity, insertInto: seedContext)
                    if entity.attributesByName["page"] != nil {
                        row.setValue(URL(string: "https://example.com/\(index)"), forKey: "page")
                    }
                    if entity.attributesByName["creationDate_"] != nil {
                        row.setValue(Date(), forKey: "creationDate_")
                    }
                    if entityName == "DeepConfiguration" {
                        row.setValue(URL(string: "file:///legacy-\(index).mlmodel"), forKey: "file_")
                        row.setValue("Legacy author \(index)", forKey: "author")
                        row.setValue("Legacy model \(index)", forKey: "modelDescription")
                        row.setValue("legacy-\(index)", forKey: "modelVersion")
                        row.setValue("classify", forKey: "modelType")
                    }
                }
            }
            try seedContext.save()
        }
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
            Migration is single-hop, so the operative mapping here is 0.0.0→0.0.2 — \
            not 0.0.0→0.0.1. If either the 0.0.0 or the current 0.0.2 model changed, \
            the 0.0.0→0.0.2 mapping model must be recreated in Xcode (its xcmapping \
            embeds the version hashes of both models).
            """
        )
        guard loadError == nil else { return }

        // 3. Every seeded row survived and the policy filled entityIds —
        //    for ALL entities FillEntityIdIfNilPolicy is assigned to.
        let context = container.viewContext
        for entityName in seededEntities {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            let migrated = try context.fetch(request)
            XCTAssertEqual(migrated.count, 3, "\(entityName) rows did not survive the migration")
            for row in migrated {
                XCTAssertNotNil(row.value(forKey: "entityId"), "FillEntityIdIfNilPolicy did not fill entityId on \(entityName)")
            }
        }

        // 4. Legacy DeepConfiguration metadata survives the custom migration policy and the
        // newly-added optional license has the expected nil default.
        let configurations = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DeepConfiguration"))
        XCTAssertEqual(
            Set(configurations.compactMap { $0.value(forKey: "file_") as? URL }.map(\.absoluteString)),
            Set((0..<3).map { "file:///legacy-\($0).mlmodel" })
        )
        XCTAssertEqual(
            Set(configurations.compactMap { $0.value(forKey: "author") as? String }),
            Set((0..<3).map { "Legacy author \($0)" })
        )
        XCTAssertEqual(
            Set(configurations.compactMap { $0.value(forKey: "modelTypeString") as? String }),
            ["classify"]
        )
        XCTAssertTrue(
            configurations.allSatisfy { ($0.value(forKey: "modelTypeParsed") as? Bool) == false },
            "AIA-0402 must re-derive this new default after migration"
        )
        XCTAssertEqual(
            Set(configurations.compactMap { $0.value(forKey: "modelVersion") as? String }),
            Set((0..<3).map { "legacy-\($0)" })
        )
        XCTAssertEqual(
            Set(configurations.compactMap { $0.value(forKey: "modelDescription") as? String }),
            Set((0..<3).map { "Legacy model \($0)" })
        )
        XCTAssertTrue(configurations.allSatisfy { $0.value(forKey: "license") == nil })
		XCTAssertTrue(
			configurations.allSatisfy { ($0.value(forKey: "annotationSoundEnabled") as? Bool) == false },
			"Migrated models must remain silent until the user explicitly enables sound."
		)
		XCTAssertTrue(
			configurations.allSatisfy { ($0.value(forKey: "annotationSoundIdentifier") as? String) == AnnotationSound.chime.rawValue },
			"Chime is the persisted migration default."
		)
		XCTAssertTrue(
			configurations.allSatisfy { abs((($0.value(forKey: "annotationSoundVolume") as? Double) ?? -1) - 0.2) < 0.0001 },
			"The persisted migration default must preserve the 20% annotation-only volume."
		)

        // 5. The new Finding entity is usable in the migrated store.
        XCTAssertNotNil(container.managedObjectModel.entitiesByName["Finding"])
    }

    /// The other live upgrade source (AIA-0651): 0.0.1 shipped `Finding` without `author`, so an
    /// installation already on 0.0.1 migrates 0.0.1→0.0.2 directly — a path the 0.0.0 test above
    /// cannot cover, because Core Data never chains hops. Findings written before the field existed
    /// must survive with their content intact and simply have no author.
    func testMigrationFromReleased_0_0_1_Store_PreservesFindingsAndLeavesAuthorNil() throws {
        // 1. Seed a store with the released 0.0.1 model (version file "MLBrowser_0.0.1.mom").
        let sourceModelURL = try momdURL().appendingPathComponent("MLBrowser_0.0.1.mom")
        let sourceModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: sourceModelURL))
        // Same reason as above: the app's NSManagedObject subclasses match the CURRENT
        // schema, and their awakeFromInsert would touch attributes 0.0.1 does not have.
        for entity in sourceModel.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }

        let seedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
        try seedCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let seedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        seedContext.persistentStoreCoordinator = seedCoordinator

        let seededTitles = ["Legacy hillfort", "Legacy burial mound"]
        // Captured so the assertions can demand the SAME identity back, not merely a non-nil one.
        var seededIdentity: [String: (id: UUID, screenshot: String)] = [:]
        try seedContext.performAndWait {
            let findingEntity = sourceModel.entitiesByName["Finding"]!
            for title in seededTitles {
                let row = NSManagedObject(entity: findingEntity, insertInto: seedContext)
                // entityId and lifeCycleString are non-optional with no default in 0.0.1:
                // omitting either fails validation on save, before any migration happens.
                let entityId = UUID()
                // FindingScreenshotStore names every file "<entityId>.png", which is why the
                // identity below is load-bearing rather than cosmetic.
                let screenshot = "\(entityId.uuidString).png"
                seededIdentity[title] = (entityId, screenshot)
                row.setValue(entityId, forKey: "entityId")
                row.setValue(screenshot, forKey: "screenshotFilename")
                row.setValue(CoreDataManageableState.ready.rawValue, forKey: "lifeCycleString")
                row.setValue(title, forKey: "title")
                row.setValue(Date(), forKey: "creationDate_")
            }
            // A second entity, so the assertions below cannot pass on an empty/partial store.
        let historyEntity = sourceModel.entitiesByName["WebHistoryEntry"]!
            let historyRow = NSManagedObject(entity: historyEntity, insertInto: seedContext)
            historyRow.setValue(UUID(), forKey: "entityId")
            historyRow.setValue(CoreDataManageableState.ready.rawValue, forKey: "lifeCycleString")
            historyRow.setValue(URL(string: "https://example.com/legacy"), forKey: "page")
        historyRow.setValue(Date(), forKey: "creationDate_")

		// Exercise the other direct mapping's new DeepConfiguration defaults too. The model row is
		// intentionally plain NSManagedObject, as above, because its source schema predates the
		// current generated subclass properties.
		let configurationEntity = sourceModel.entitiesByName["DeepConfiguration"]!
		let configuration = NSManagedObject(entity: configurationEntity, insertInto: seedContext)
		configuration.setValue(UUID(), forKey: "entityId")
		configuration.setValue(CoreDataManageableState.ready.rawValue, forKey: "lifeCycleString")
		configuration.setValue(URL(string: "file:///legacy-0.0.1.mlmodel"), forKey: "file_")
		configuration.setValue("Legacy 0.0.1 model", forKey: "modelDescription")
            try seedContext.save()
        }
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
            Migration from the released 0.0.1 store failed: \(String(describing: loadError)). \
            Adding Finding.author to 0.0.2 requires an explicit 0.0.1→0.0.2 mapping model \
            recreated in Xcode; inference is off in release builds, so a missing or stale \
            mapping strands every user who is already on 0.0.1.
            """
        )
        guard loadError == nil else { return }

        // 3. The pre-author findings survived intact, and the new column is simply empty.
        let context = container.viewContext
        let migrated = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Finding"))
        XCTAssertEqual(migrated.count, seededTitles.count, "Finding rows did not survive the migration")
        XCTAssertEqual(
            Set(migrated.compactMap { $0.value(forKey: "title") as? String }),
            Set(seededTitles),
            "migrated findings lost their titles"
        )
        for row in migrated {
            XCTAssertNil(row.value(forKey: "author"), "a finding written before AIA-0651 has no author")
            let title = try XCTUnwrap(row.value(forKey: "title") as? String)
            let seeded = try XCTUnwrap(seededIdentity[title], "migration invented a finding titled \(title)")
            // Asserting merely non-nil would pass a migration that REGENERATED every id. That is not
            // a cosmetic difference: the screenshot on disk is named "<entityId>.png", so a new id
            // silently orphans the picture and the finding renders as a grey placeholder for ever.
            XCTAssertEqual(
                row.value(forKey: "entityId") as? UUID,
                seeded.id,
                "migration must preserve the existing entityId, not mint a new one"
            )
            XCTAssertEqual(
                row.value(forKey: "screenshotFilename") as? String,
                seeded.screenshot,
                "a migrated finding must still point at the screenshot it was saved with"
            )
        }

        let history = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WebHistoryEntry"))
        XCTAssertEqual(history.count, 1, "unrelated entities must survive the 0.0.1→0.0.2 hop too")
		let configurations = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DeepConfiguration"))
		XCTAssertEqual(configurations.count, 1)
		let configuration = try XCTUnwrap(configurations.first)
		XCTAssertEqual(configuration.value(forKey: "annotationSoundEnabled") as? Bool, false)
		XCTAssertEqual(configuration.value(forKey: "annotationSoundIdentifier") as? String, AnnotationSound.chime.rawValue)
		let volume = try XCTUnwrap(configuration.value(forKey: "annotationSoundVolume") as? Double)
		XCTAssertEqual(volume, 0.2, accuracy: 0.0001)
    }
}

// MARK: - modifiedAt write-path choke point (AIA-713)

/// `Finding.willSave()` is the ONE place `modifiedAt` is stamped, so that no writer — present or
/// future, sync-aware or not — can persist a change without advancing the last-write-wins key.
/// These tests pin the two halves that are easy to get wrong: the automatic stamp must fire on
/// every ordinary mutation, and it must NOT fire for a writer carrying an authoritative timestamp.
@MainActor
final class FindingModifiedAtTests: XCTestCase {
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

    private func makeReadyFinding() throws -> Finding {
        let finding = Finding.create(in: moc)
        finding.creationDate_ = .now
        finding.title = "Choke point"
        finding.page = URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
        finding.screenshotFilename = Finding.screenshotFilename(for: finding.entityId)
        finding.boxX = 0.25
        finding.boxY = 0.25
        finding.boxWidth = 0.5
        finding.boxHeight = 0.5
        finding.detectionConfidence = 0.9
        finding.transition(to: .draft)
        finding.transition(to: .ready)
        try Finding.save(in: moc)
        return finding
    }

    func testSave_StampsModifiedAt() throws {
        let finding = try makeReadyFinding()
        XCTAssertNotNil(finding.modifiedAt, "willSave must stamp modifiedAt on the first save")
    }

    func testMutation_AdvancesModifiedAt() throws {
        let finding = try makeReadyFinding()
        let first = try XCTUnwrap(finding.modifiedAt)

        finding.note_ = "revised in the field"
        try Finding.save(in: moc)

        let second = try XCTUnwrap(finding.modifiedAt)
        XCTAssertGreaterThan(
            second, first,
            "an ordinary mutation must advance modifiedAt, or last-write-wins cannot order two edits"
        )
    }

    /// The case an equality-based guard silently gets wrong: an authoritative writer sets
    /// `modifiedAt` AND another attribute. Assigning a value equal to the committed one leaves
    /// `changedValues()` empty, so only the explicit flag can stop the automatic stamp.
    func testPreservesModifiedAt_KeepsTheAuthoritativeTimestamp() throws {
        let finding = try makeReadyFinding()
        let authoritative = Date(timeIntervalSince1970: 1_000_000)

        finding.preservesModifiedAt = true
        finding.modifiedAt = authoritative
        finding.note_ = "restored from an archive"
        try Finding.save(in: moc)

        XCTAssertEqual(
            finding.modifiedAt, authoritative,
            "an import/sync writer's timestamp must survive; stamping now would hand this device a false LWW win"
        )
    }

    /// The case that actually requires the flag, and the reason an equality guard alone is not
    /// enough: the authoritative timestamp EQUALS the committed one, so assigning it leaves
    /// `changedValues()` empty and `changedValues()["modifiedAt"] == nil` is true. Without
    /// `preservesModifiedAt` the stamp fires and silently overwrites the value the caller supplied.
    /// (Verified by mutation: deleting the flag check from `willSave()` fails THIS test and no other.)
    func testPreservesModifiedAt_WhenTheTimestampEqualsTheCommittedValue() throws {
        let finding = try makeReadyFinding()
        let committed = try XCTUnwrap(finding.modifiedAt)

        finding.preservesModifiedAt = true
        finding.modifiedAt = committed // equal — contributes nothing to changedValues()
        finding.note_ = "restored from an archive whose timestamp matches"
        try Finding.save(in: moc)

        XCTAssertEqual(
            finding.modifiedAt, committed,
            "the flag, not changedValues(), is what suppresses the stamp when the timestamp is unchanged"
        )
    }

    /// Same object, flag cleared: the very next ordinary save must resume stamping, so the
    /// suppression cannot leak past the one write it was meant for.
    func testClearingTheFlag_ResumesStamping() throws {
        let finding = try makeReadyFinding()
        let authoritative = Date(timeIntervalSince1970: 1_000_000)
        finding.preservesModifiedAt = true
        finding.modifiedAt = authoritative
        try Finding.save(in: moc)

        finding.preservesModifiedAt = false
        finding.note_ = "edited by the user afterwards"
        try Finding.save(in: moc)

        XCTAssertGreaterThan(
            try XCTUnwrap(finding.modifiedAt), authoritative,
            "clearing preservesModifiedAt must restore the automatic stamp"
        )
    }

    /// A deleted object must not be re-dirtied by the stamp — that would push a pending delete
    /// back into the context and can fail the save outright.
    func testDelete_DoesNotThrow() throws {
        let finding = try makeReadyFinding()
        moc.delete(finding)
        XCTAssertNoThrow(try moc.save(), "stamping must skip deleted objects")
        XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0)
    }
}
