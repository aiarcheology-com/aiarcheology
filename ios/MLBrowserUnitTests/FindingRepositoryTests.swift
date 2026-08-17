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
			metadata: FindingMetadata(title: "Test finding", label: " site ", note: "", author: "", gps: "")
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
				metadata: FindingMetadata(title: "   ", label: "", note: "", author: "", gps: "")
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
			metadata: FindingMetadata(title: "Cropped edge finding", label: "", note: "", author: "", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(finding.lifeCycle, .ready)
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1)
		XCTAssertTrue(finding.validationReport().isValid)
		XCTAssertNotNil(FindingScreenshotStore.load(filename: finding.screenshotFilename))
	}

	// MARK: - Author (AIA-0651)

	/// The gate on the whole field: a NON-empty author must come back out of the store.
	/// Asserting only "not something else" would still pass if the value were dropped on the way in
	/// (`FindingMetadata.author` carries no default precisely so a call site cannot omit it).
	func testSave_authorProvided_persistsTheAuthor() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Signed finding", label: "", note: "", author: "Jane Archeologist", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(finding.author, "Jane Archeologist", "the finder's credit round-trips verbatim")
	}

	/// Same normalization rule as label/note/gps: a field the user only put spaces in is absent, not
	/// an empty string — the share card and the export both branch on nil.
	func testSave_whitespaceOnlyAuthor_persistsNil() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Unsigned finding", label: "", note: "", author: "   \n ", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertNil(finding.author, "a whitespace-only author is absent, not an empty string")
	}

	/// AC #4: the author is per-finding state. Editing (or clearing) one row must not reach any
	/// other — the failure mode of a credit sourced from one shared/global value at read time.
	func testSave_editingOneAuthor_leavesOtherFindingsUntouched() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let first = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "First finding", label: "", note: "", author: "Jane Archeologist", gps: "")
		)
		let second = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Second finding", label: "", note: "", author: "Karol Nálezca", gps: "")
		)
		defer {
			FindingScreenshotStore.delete(filename: first.screenshotFilename)
			FindingScreenshotStore.delete(filename: second.screenshotFilename)
		}

		first.author = "Renamed Finder"
		try Finding.save(in: moc)
		XCTAssertEqual(second.author, "Karol Nálezca", "renaming one finder rewrote another finding's credit")

		second.author = nil
		try Finding.save(in: moc)
		XCTAssertEqual(first.author, "Renamed Finder", "clearing one finder's credit erased another finding's")
	}

	/// AC #3: the share card reads its byline off `FindingShareSubject`, which is built only from a
	/// managed object (`init(_:)` — there is no memberwise init to fake), so this is the sole path.
	func testShareSubject_fromSavedFinding_carriesTheAuthorAndNilWhenBlank() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let credited = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Credited finding", label: "", note: "", author: "Jane Archeologist", gps: "")
		)
		let anonymous = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Anonymous finding", label: "", note: "", author: " ", gps: "")
		)
		defer {
			FindingScreenshotStore.delete(filename: credited.screenshotFilename)
			FindingScreenshotStore.delete(filename: anonymous.screenshotFilename)
		}

		XCTAssertEqual(FindingShareSubject(credited).author, "Jane Archeologist")
		// The card renders the byline only when non-nil, so this is what keeps it from inventing one.
		XCTAssertNil(FindingShareSubject(anonymous).author)
	}

	/// The export path end to end: `allFindingSnapshots()` maps rows through `FindingSnapshot.init(_:)`,
	/// the ONLY production producer of an export snapshot. Deliberately not built with the memberwise
	/// init — that would assert the encoder, not the copy, and would pass with the copy deleted.
	func testAllFindingSnapshots_savedAuthor_survivesIntoTheSnapshot() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let credited = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Credited finding", label: "", note: "", author: "Jane Archeologist", gps: "")
		)
		let anonymous = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Anonymous finding", label: "", note: "", author: "", gps: "")
		)
		defer {
			FindingScreenshotStore.delete(filename: credited.screenshotFilename)
			FindingScreenshotStore.delete(filename: anonymous.screenshotFilename)
		}

		let snapshots = sut.allFindingSnapshots()
		XCTAssertEqual(snapshots.count, 2)
		let creditedSnapshot = try XCTUnwrap(snapshots.first { $0.id == credited.entityId })
		let anonymousSnapshot = try XCTUnwrap(snapshots.first { $0.id == anonymous.entityId })

		XCTAssertEqual(creditedSnapshot.author, "Jane Archeologist")
		XCTAssertNil(anonymousSnapshot.author)
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
