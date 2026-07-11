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
	}
}
