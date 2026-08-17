//
//  RemoveAllFindingsTests.swift
//  MLBrowserUnitTests
//
//  AIA-0303: proves Settings → Reset → "Remove Findings" behavior end to end against a
//  DISK-BACKED store. In-memory is invalid here — NSBatchDeleteRequest no-ops on an
//  NSInMemoryStore, so `DataController(inMemory:true)` (used by FindingRepositoryTests) would
//  make these tests green while deleting nothing. Isolation follows the shipped FindingsTests
//  sweepOrphans pattern: assert on the SPECIFIC seeded filenames and clean up only our own
//  files — never "the Findings directory is empty" (that would race parallel finding tests that
//  share the process-global Documents/Findings).
//

import XCTest
import UIKit
import CoreData
@testable import ML_Browser

@MainActor
final class RemoveAllFindingsTests: XCTestCase {

	private var storeURL: URL!
	private var dataController: DataController!
	private var sut: FindingRepository!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		// Disk-backed SQLite store (unique per test) so the batch delete actually executes.
		storeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("RemoveAllFindings-\(UUID().uuidString).sqlite")
		dataController = DataController(storeURL: storeURL)
		await dataController.awaitStoreReady()
		sut = FindingRepository(dataController: dataController)
	}

	override func tearDown() async throws {
		sut = nil
		dataController = nil
		if let url = storeURL {
			for suffix in ["", "-wal", "-shm"] {
				try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
			}
		}
		storeURL = nil
		try await super.tearDown()
	}

	// MARK: - Helpers (mirroring FindingRepositoryTests)

	private func makeImage() -> UIImage {
		UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
			UIColor.gray.setFill()
			ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
		}
	}

	private func makeCapture(box: CGRect) -> FindingCapture {
		FindingCapture(
			observation: DetectedObject(uuid: UUID(), labels: [], confidence: 0.9, boundingBox: box, regionIndex: 0),
			params: nil,
			frame: AppliedDetectionFrame(image: makeImage(), results: []),
			pageURL: URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
		)
	}

	@discardableResult
	private func seedFinding(title: String) throws -> String {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: title, label: "site", note: "", author: "", gps: "")
		)
		return try XCTUnwrap(finding.screenshotFilename, "a saved finding has a screenshot filename")
	}

	private func fileExists(_ filename: String) throws -> Bool {
		let url = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))
		return FileManager.default.fileExists(atPath: url.path)
	}

	// MARK: - Remove Findings

	func test_removeAllFindings_deletesEverySeededRowAndScreenshot() async throws {
		// Register each cleanup immediately after its seed: if a later seed throws, the earlier
		// file's defer is already installed, so nothing leaks into the shared findings directory.
		let fileA = try seedFinding(title: "Finding A")
		defer { FindingScreenshotStore.delete(filename: fileA) }
		let fileB = try seedFinding(title: "Finding B")
		defer { FindingScreenshotStore.delete(filename: fileB) }

		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 2, "two findings were seeded")
		XCTAssertTrue(try fileExists(fileA) && (try fileExists(fileB)), "both screenshots are on disk before removal")

		try await sut.removeAllFindings()

		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0, "every finding row is deleted")
		XCTAssertFalse(try fileExists(fileA), "finding A's screenshot is swept")
		XCTAssertFalse(try fileExists(fileB), "finding B's screenshot is swept")
	}

	func test_removeAllFindings_onEmptyStore_isNoOp() async throws {
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0, "store starts empty")
		// Must not throw and must leave the (empty) store consistent.
		try await sut.removeAllFindings()
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0, "still empty, no crash")
	}

	func test_snapshotsAndHasAnyFinding_reflectTheStore() async throws {
		XCTAssertFalse(sut.hasAnyFinding(), "empty store has no findings")
		XCTAssertTrue(sut.allFindingSnapshots().isEmpty, "empty store snapshots to nothing")

		let fileA = try seedFinding(title: "Finding A")
		defer { FindingScreenshotStore.delete(filename: fileA) }
		let fileB = try seedFinding(title: "Finding B")
		defer { FindingScreenshotStore.delete(filename: fileB) }

		XCTAssertTrue(sut.hasAnyFinding(), "hasAnyFinding is true once findings exist")
		XCTAssertEqual(sut.allFindingSnapshots().count, 2, "every stored finding is snapshotted for export")

		try await sut.removeAllFindings()

		XCTAssertFalse(sut.hasAnyFinding(), "hasAnyFinding is false after removal")
		XCTAssertTrue(sut.allFindingSnapshots().isEmpty, "no snapshots after removal")
	}

	// MARK: - AC5: Restore Defaults must NOT remove findings

	func test_restoreDefaults_preservesFindings() async throws {
		let file = try seedFinding(title: "Survivor")
		defer { FindingScreenshotStore.delete(filename: file) }

		// Drive the REAL reset path that "Restore Defaults" invokes (AppChromeState.resetApplication),
		// composed on the same disk-backed store — a future edit that made the reset delete findings
		// must fail here. resetApplication also reseeds demo data (model IO), which is orthogonal to
		// findings; we only assert the finding survives.
		let settings = Settings()
		let detection = DetectionSessionState(
			snap: SnapState(settings: settings),
			settings: settings,
			snapAdjustment: SnapAdjustment()
		)
		let chrome = AppChromeState(
			detectionState: detection,
			deep: DeepState(dataController: dataController),
			settings: settings,
			demoDataManager: DemoDataManager(dataController: dataController),
			analytics: nil
		)

		await chrome.resetApplication()

		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1, "Restore Defaults must not remove findings")
		XCTAssertTrue(try fileExists(file), "the finding screenshot survives Restore Defaults")
	}
}
