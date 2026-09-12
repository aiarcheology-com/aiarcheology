//
//  FindingRepositoryTests.swift
//  MLBrowserUnitTests
//
//  AIA-0392: proves the Finding persist transaction — extracted out of SaveFindingSheet into
//  FindingRepository — is unit-testable in isolation (Core Data + screenshot store, no View):
//  the success path persists a ready finding + its PNG, and the failure path rolls BOTH back.
//

import XCTest
import UIKit
import CoreData
@testable import ML_Browser

@MainActor
final class FindingRepositoryTests: XCTestCase {

	private var dataController: DataController!
	private var sut: FindingRepository!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		// Await store readiness before touching `viewContext`, matching the rest of the suite.
		// (The in-memory store actually loads synchronously, so there is no real race — this keeps
		// the tests robust to that assumption and consistent with the other Core Data tests.)
		await dataController.awaitStoreReady()
		sut = FindingRepository(dataController: dataController)
	}

	override func tearDown() async throws {
		sut = nil
		dataController = nil
		try await super.tearDown()
	}

	/// A 10×10 opaque image so `FindingScreenshotStore.save` writes a real PNG.
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

	func testSave_validFinding_persistsReadyRowAndScreenshot() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Test finding", label: " site ", note: "", gps: "")
		)
		// The PNG is written to the real Documents dir even under an in-memory store — clean it up.
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(finding.lifeCycle, .ready, "a persisted finding is ready")
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1, "exactly one row is persisted")
		XCTAssertNotNil(FindingScreenshotStore.load(filename: finding.screenshotFilename), "the PNG exists on disk")
		XCTAssertEqual(finding.screenshotFilename, Finding.screenshotFilename(for: finding.entityId),
					   "filename is keyed to the entity id (validation invariant)")
		XCTAssertEqual(finding.title, "Test finding", "title is persisted trimmed")
		XCTAssertEqual(finding.label_, "site", "label is trimmed/normalized")
	}

	func testSave_invalidFinding_throwsAndRollsBackRowAndScreenshot() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		// Snapshot the on-disk screenshot dir so we can prove the rollback deletes the PNG too —
		// not just the Core Data row. This exercises the repository catch-block's file cleanup;
		// a regression that left an orphaned screenshot (while still throwing) would fail here.
		let before = Self.screenshotFilenames()
		// Empty title fails validationReport → the whole transaction must roll back.
		XCTAssertThrowsError(
			try sut.save(
				capture: makeCapture(box: box),
				image: makeImage(),
				box: box,
				metadata: FindingMetadata(title: "   ", label: "", note: "", gps: "")
			)
		)
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0, "no row survives a failed save")
		XCTAssertEqual(Self.screenshotFilenames(), before, "a failed save leaves no orphaned screenshot on disk")
	}

	func testSave_cropEdgeRemappedBox_persistsReadyRowAndScreenshot() throws {
		let crop = CGRect(x: 0.053, y: 0.053, width: 0.211, height: 0.211)
		let side = crop.width / 3
		let topLeftBox = CGRect(x: crop.maxX - side, y: crop.maxY - side, width: side, height: side)
		let visionBox = CGRect(
			x: topLeftBox.minX,
			y: 1 - topLeftBox.maxY,
			width: topLeftBox.width,
			height: topLeftBox.height
		)
		let remappedBox = FindingCapture.remappedBox(visionBox, into: crop)

		let finding = try sut.save(
			capture: makeCapture(box: visionBox),
			image: makeImage(),
			box: remappedBox,
			metadata: FindingMetadata(title: "Cropped edge finding", label: "", note: "", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(finding.lifeCycle, .ready)
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1)
		XCTAssertTrue(finding.validationReport().isValid)
		XCTAssertNotNil(FindingScreenshotStore.load(filename: finding.screenshotFilename))
	}

	/// Current filenames in the shared `Documents/Findings` dir (the store's write target),
	/// derived via the store's public URL helper so the test needn't know the absolute path.
	private static func screenshotFilenames() -> Set<String> {
		guard let dir = FindingScreenshotStore.url(forFilename: "probe.png")?.deletingLastPathComponent(),
			  let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
		else { return [] }
		return Set(urls.map(\.lastPathComponent))
	}
}
