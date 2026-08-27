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
	///
	/// Scope note: this mutates the managed objects directly, because `FindingDetailView` is a
	/// private SwiftUI view with no seam to drive from a unit test. So it proves the *storage* is
	/// per-row; it does not prove the detail editor writes it. If `saveEdits()` stopped assigning
	/// `finding.author`, or `hasChanges` stopped observing it, this test would still pass and the
	/// user's edit would silently not save — covered instead by TestFlight notes step 5.
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

	/// Covers the *data* half of AC #3: the byline the card renders comes from
	/// `FindingShareSubject`, which can only be built from a managed object (`init(_:)` — there is
	/// no memberwise init to fake), so a dropped copy fails here.
	///
	/// It does **not** cover the rendering half. Deleting the author `Label` from
	/// `FindingShareCard` leaves this green while shared cards stop showing the author — there is no
	/// snapshot-test target, and adding one for this ticket would be scope. That half is a manual
	/// check on the composer, and step 1 of the TestFlight notes asks a tester to confirm it.
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

	// MARK: - Capture-space box (AIA-0761)

	/// The two rectangles have to stay apart on the row. The save sheet re-normalizes the detection
	/// into the crop it bakes into the image, so the caller's `box` and the detection's own place on
	/// the captured view genuinely differ on nearly every save — one field cannot hold both.
	///
	/// The share assertion is the half a value-initialized subject cannot reach:
	/// `FindingShareSubject.init(_ finding:)` is the only way a browsed finding enters the share
	/// contract, so a copy dropped there leaves every emission test green while every real link goes
	/// out pointing at the crop.
	func testSave_croppedFinding_recordsBothBoxesAndSharesTheCaptureOne() throws {
		let captureBox = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
		let cropBox = CGRect(x: 0.6, y: 0.5, width: 0.25, height: 0.4)
		let finding = try sut.save(
			capture: makeCapture(box: captureBox),
			image: makeImage(),
			box: cropBox,
			metadata: FindingMetadata(title: "Cropped finding", label: "", note: "", author: "", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(finding.normalizedBox, cropBox, "the stored image's box is the one the caller passed")
		XCTAssertEqual(
			finding.captureNormalizedBox, captureBox,
			"the capture box is the detection's own, not the crop-relative one"
		)

		let box = try XCTUnwrap(FindingShareSubject(finding).linkPayload().box)
		XCTAssertEqual(box.x, captureBox.minX, accuracy: 1e-9)
		XCTAssertEqual(box.y, 1 - captureBox.maxY, accuracy: 1e-9)
		XCTAssertEqual(box.width, captureBox.width, accuracy: 1e-9)
		XCTAssertEqual(box.height, captureBox.height, accuracy: 1e-9)
		XCTAssertNotEqual(box.x, cropBox.minX, accuracy: 1e-9, "the stored image's box reached the link")
	}

	/// Exercises `FindingSnapshot.init(_:)`, which every production export goes through — this one via
	/// `allFindingSnapshots()` (the export-before-delete flow), the Findings list via
	/// `filteredFindings.map(FindingSnapshot.init)`. Deliberately NOT built with the memberwise init:
	/// that would assert the encoder rather than the copy, and would stay green with the copy deleted.
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

	// MARK: - Editing (AIA-737)

	func testCommitEdits_persistsTheEditAndTellsSyncAboutIt() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Before", label: "", note: "", author: "", gps: "")
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		let stampBeforeEdit = finding.modifiedAt
		var changeNotifications = 0
		sut.didChangeFindings = { changeNotifications += 1 }

		finding.title = "After"
		try sut.commitEdits()

		XCTAssertEqual(finding.title, "After", "the edit is persisted")
		XCTAssertFalse(moc.hasChanges, "the edit is committed, not left pending in the context")
		// The two assertions that matter together. Editing used to call `Finding.save(in:)` directly:
		// the row changed and its stamp moved, but nothing rang, so sync learned about the edit only
		// when an unrelated trigger happened to fire next. Either half alone passes a broken build --
		// a bell with no stamp change uploads nothing, a stamp change with no bell uploads late.
		XCTAssertEqual(changeNotifications, 1, "an edit rings the bell create and delete ring")
		XCTAssertNotEqual(finding.modifiedAt, stampBeforeEdit, "the edit re-stamps modifiedAt, so it is owed")
	}

	// MARK: - Importing a capture box (AIA-0761)

	/// Nil on the wire means "not stated", never "there is none". This is asserted against
	/// `importFindings` — `apply`'s public entry point — rather than through the sync cycle harness,
	/// because the rule lives in `apply` and a stubbed-Worker round trip would exercise HTTP, zip
	/// and ledger code to reach the same three lines.
	///
	/// It matters because cloud sync replace-imports without anyone touching anything: if nil wrote
	/// zeroes, one peer still on an older build would strip the capture box off every device the
	/// account owns, permanently and silently.
	func testImportFindings_replaceWithNoStatedCaptureBox_keepsTheLocalOne() throws {
		let captureBox = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
		let finding = try sut.save(
			capture: makeCapture(box: captureBox),
			image: makeImage(),
			box: CGRect(x: 0.6, y: 0.5, width: 0.25, height: 0.4),
			metadata: FindingMetadata(title: "Local", label: "", note: "", author: "", gps: "")
		)
		let id = finding.entityId
		defer { FindingScreenshotStore.delete(filename: Finding.screenshotFilename(for: id)) }

		let unstated = try sut.importFindings(archive(id: id, captureBox: nil), duplicates: .replace)
		XCTAssertEqual(unstated.restored, 1, "precondition: the row was actually replaced")
		XCTAssertEqual(
			try XCTUnwrap(Finding.select(id, in: moc)).captureNormalizedBox, captureBox,
			"an archive that does not state a capture box must not blank the one this device knows"
		)

		let stated = try sut.importFindings(
			archive(id: id, captureBox: .init(x: 0.4, y: 0.3, width: 0.2, height: 0.1)),
			duplicates: .replace
		)
		XCTAssertEqual(stated.restored, 1)
		XCTAssertEqual(
			try XCTUnwrap(Finding.select(id, in: moc)).captureNormalizedBox,
			CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.1),
			"a stated capture box is the sender's own fact and replaces the local value"
		)
	}

	/// One archived row for `id`, carrying whatever capture box the case under test needs.
	private func archive(id: UUID, captureBox: FindingSnapshot.Box?) -> FindingArchiveContents {
		FindingArchiveContents(
			rows: [
				ImportedFindingRow(
					id: id,
					title: "Imported",
					label: nil,
					note: nil,
					author: nil,
					gps: nil,
					page: URL(string: "https://example.com/a"),
					detectionClass: nil,
					confidence: 0.5,
					creationDate: nil,
					box: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
					captureBox: captureBox,
					modifiedAt: nil,
					modelId: nil,
					lifeCycle: CoreDataManageableState.ready.rawValue,
					screenshotExtension: nil
				)
			],
			images: [:]
		)
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
