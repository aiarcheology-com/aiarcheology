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

	/// AIA-0817: every other call site passes `page: nil`, so without this nothing would notice if
	/// `save` went back to reading the capture's URL and ignoring the editor's value.
	func testSave_StoresTheMetadataPage_NotTheCapturesOwnURL() throws {
		let edited = URL(string: "https://www.freemap.sk/#map=15/47.941230/18.709545")!
		let finding = try sut.save(
			capture: makeCapture(box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
			image: makeImage(),
			box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			metadata: FindingMetadata(
				title: "Edited page", label: "", note: "", author: "", gps: "", page: edited
			)
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }
		// The capture carries a DIFFERENT URL, so this fails if `save` reads the capture again.
		XCTAssertEqual(finding.page, edited)
		XCTAssertNotEqual(finding.page?.host, "zbgis.skgeodesy.sk")
	}

	private func makeCapture(box: CGRect) -> FindingCapture {
		FindingCapture(
			observation: DetectedObject(uuid: UUID(), labels: [], confidence: 0.9, boundingBox: box, regionIndex: 0),
			params: nil,
			frame: AppliedDetectionFrame(image: makeImage(), results: []),
			pageURL: URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
		)
	}

	// MARK: - AIA-0846: a saved finding is coherent end to end

	/// An image whose centre pixel is a colour no other test uses, so the stored PNG can be told
	/// apart from any other page's pixels.
	private func markedImage(_ marker: UIColor) -> UIImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		return UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { ctx in
			marker.setFill()
			ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
		}
	}

	private func centrePixel(of image: UIImage?) -> [UInt8]? {
		guard let cgImage = image?.cgImage else { return nil }
		var pixel = [UInt8](repeating: 0, count: 4)
		let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext(
				data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.draw(cgImage, in: CGRect(x: -CGFloat(cgImage.width) / 2, y: -CGFloat(cgImage.height) / 2,
			                                 width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
			return true
		}
		return drawn ? pixel : nil
	}

	/// The image, its detection box, its page and its coordinate are all the ones captured together
	/// under one context, and the sheet's own prefill path (page text from `pageURL`, GPS from
	/// `gpsPrefill`) carries them into the row unchanged. A user edit still wins, as before.
	func testSave_ContextBoundCapture_RoundTripsImageBoxPageAndLocationTogether() throws {
		let pageA = try XCTUnwrap(URL(string: "https://example.org/map#map=15/47.941230/18.709545"))
		let context = CaptureContext(documentRevision: 3, sourceURL: pageA, liveURL: pageA, frameRevision: 0)
		let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
		let location = MapPageLocation(
			sourceURL: pageA,
			reading: MapLocationReading(coordinate: try XCTUnwrap(MapCoordinate(latitude: 47.94123, longitude: 18.709545)), source: .leaflet)
		)
		let capture = FindingCapture(
			observation: DetectedObject(uuid: UUID(), labels: [], confidence: 0.9, boundingBox: box, regionIndex: 0),
			params: nil,
			frame: AppliedDetectionFrame(
				image: markedImage(.red),
				results: [],
				provenance: SnapshotProvenance(context: context, isCoherent: true)
			),
			location: location
		)
		let gps = try XCTUnwrap(capture.location.gpsPrefill)

		let finding = try sut.save(
			capture: capture,
			image: capture.frame.image,
			box: box,
			metadata: FindingMetadata(
				title: "Coherent", label: "", note: "", author: "", gps: gps,
				page: FindingPageURL.resolve(edited: capture.pageURL?.absoluteString ?? "", captured: capture.pageURL)
			)
		)
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }

		XCTAssertEqual(capture.frame.provenance.context?.sourceURL, capture.pageURL, "the image's page is the recorded page")
		XCTAssertEqual(finding.page, pageA)
		XCTAssertEqual(finding.gps_, gps)
		XCTAssertEqual(finding.captureBoxX, box.minX)
		XCTAssertEqual(finding.captureBoxY, box.minY)
		XCTAssertEqual(finding.captureBoxWidth, box.width)
		XCTAssertEqual(finding.captureBoxHeight, box.height)
		// Tolerant per channel: the PNG round trip may move a channel by a unit through colour
		// management, which says nothing about WHICH image was stored.
		let stored = try XCTUnwrap(centrePixel(of: FindingScreenshotStore.load(filename: finding.screenshotFilename)))
		XCTAssertTrue(
			stored[0] > 240 && stored[1] < 16 && stored[2] < 16,
			"the stored pixels are the captured (red-marked) image, got \(stored)"
		)
	}

	func testSave_validFinding_persistsReadyRowAndScreenshot() throws {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let finding = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Test finding", label: " site ", note: "", author: "", gps: "", page: nil)
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
				metadata: FindingMetadata(title: "   ", label: "", note: "", author: "", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Cropped edge finding", label: "", note: "", author: "", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Signed finding", label: "", note: "", author: "Jane Archeologist", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Unsigned finding", label: "", note: "", author: "   \n ", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "First finding", label: "", note: "", author: "Jane Archeologist", gps: "", page: nil)
		)
		let second = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Second finding", label: "", note: "", author: "Karol Nálezca", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Credited finding", label: "", note: "", author: "Jane Archeologist", gps: "", page: nil)
		)
		let anonymous = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Anonymous finding", label: "", note: "", author: " ", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Cropped finding", label: "", note: "", author: "", gps: "", page: nil)
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

		// The other direction of the same swap: assigning the capture box to BOTH subject fields
		// would satisfy every assertion above while the card drew a capture-space rectangle over
		// the cropped image (`FindingShareCard` renders `subject.normalizedBox`).
		XCTAssertEqual(
			FindingShareSubject(finding).normalizedBox, cropBox,
			"the card's box must stay the stored image's own"
		)
	}

	/// The archive/sync lane of AIA-0761, from a real row rather than a memberwise snapshot.
	/// `FindingSnapshot.init(_:)` is the only place a stored capture box becomes wire data, and it
	/// is the mapping that turns the zero rect into a nil — delete it and every other test stays
	/// green while devices quietly stop carrying capture boxes to each other.
	func testAllFindingSnapshots_captureBox_isCarriedFromTheRowAndNilWhenNeverRecorded() throws {
		let captureBox = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
		let recorded = try sut.save(
			capture: makeCapture(box: captureBox),
			image: makeImage(),
			box: CGRect(x: 0.6, y: 0.5, width: 0.25, height: 0.4),
			metadata: FindingMetadata(title: "Recorded", label: "", note: "", author: "", gps: "", page: nil)
		)
		defer { FindingScreenshotStore.delete(filename: recorded.screenshotFilename) }
		// A row that predates the attribute, spelled the way migration leaves one.
		recorded.captureBoxX = 0
		recorded.captureBoxY = 0
		recorded.captureBoxWidth = 0
		recorded.captureBoxHeight = 0
		let legacySnapshot = try XCTUnwrap(sut.allFindingSnapshots().first { $0.id == recorded.entityId })
		XCTAssertNil(legacySnapshot.captureBox, "the zero rect means 'never recorded' and travels as nil")

		recorded.captureBoxX = captureBox.minX
		recorded.captureBoxY = captureBox.minY
		recorded.captureBoxWidth = captureBox.width
		recorded.captureBoxHeight = captureBox.height
		let snapshot = try XCTUnwrap(sut.allFindingSnapshots().first { $0.id == recorded.entityId })

		XCTAssertEqual(
			snapshot.captureBox,
			.init(x: captureBox.minX, y: captureBox.minY, width: captureBox.width, height: captureBox.height)
		)
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
			metadata: FindingMetadata(title: "Credited finding", label: "", note: "", author: "Jane Archeologist", gps: "", page: nil)
		)
		let anonymous = try sut.save(
			capture: makeCapture(box: box),
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: "Anonymous finding", label: "", note: "", author: "", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Before", label: "", note: "", author: "", gps: "", page: nil)
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
			metadata: FindingMetadata(title: "Local", label: "", note: "", author: "", gps: "", page: nil)
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
					screenshotExtension: nil,
					// Not stated, which is what an archive written before provenance existed looks
					// like. `apply` must leave whatever the local row already has (AIA-0835).
					source: nil,
					receivedAt: nil
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

	// MARK: - The hard-link backup the import rollback depends on (AIA-0755)

	/// **This is the assertion the whole rollback rests on.**
	///
	/// `importFindings` no longer copies a replaced screenshot's bytes into memory -- it hard-links
	/// the file and lets the writer put the new picture at the same name. That is only a backup while
	/// every writer into the findings directory REPLACES BY RENAME. A writer that truncated the file
	/// in place would change the bytes behind the link, and a rollback would restore the very image it
	/// was supposed to undo -- silently, and only on a path that already went wrong.
	///
	/// The inode comparison is the real assertion; the bytes are the symptom. To prove this test can
	/// fail, change `FindingScreenshotStore.save`'s write to `options: []` and watch it go red.
	func testSaveData_replacingAnImage_leavesAHardLinkedBackupHoldingTheOldBytes() throws {
		let id = UUID()
		let before = Data(repeating: 0xA1, count: 2048)
		let after = Data(repeating: 0xB2, count: 4096)

		let filename = try FindingScreenshotStore.save(before, for: id, pathExtension: "jpg")
		let stored = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))
		let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.linkItem(at: stored, to: backup)
		defer {
			try? FileManager.default.removeItem(at: backup)
			FindingScreenshotStore.delete(filename: filename)
		}

		_ = try FindingScreenshotStore.save(after, for: id, pathExtension: "jpg")

		XCTAssertEqual(try Data(contentsOf: stored), after)
		XCTAssertEqual(try Data(contentsOf: backup), before, "the backup followed the new write")
		XCTAssertNotEqual(
			try stored.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
			try backup.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
			"the write must land on a NEW inode -- an in-place write silently voids every backup"
		)
	}

	/// The same property for the file-to-file writer an archive import uses. It has its own code
	/// path -- copy to a sibling, then swap -- so it needs its own proof.
	func testSaveCopyingFrom_replacingAnImage_leavesAHardLinkedBackupHoldingTheOldBytes() throws {
		let id = UUID()
		let before = Data(repeating: 0xC3, count: 2048)
		let after = Data(repeating: 0xD4, count: 4096)

		let filename = try FindingScreenshotStore.save(before, for: id, pathExtension: "jpg")
		let stored = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))
		let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.linkItem(at: stored, to: backup)
		let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
		try after.write(to: incoming)
		defer {
			try? FileManager.default.removeItem(at: backup)
			try? FileManager.default.removeItem(at: incoming)
			FindingScreenshotStore.delete(filename: filename)
		}

		_ = try FindingScreenshotStore.save(copyingFrom: incoming, for: id, pathExtension: "jpg")

		XCTAssertEqual(try Data(contentsOf: stored), after)
		XCTAssertEqual(try Data(contentsOf: backup), before, "the backup followed the new write")
		XCTAssertNotEqual(
			try stored.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
			try backup.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
			"the swap must land on a NEW inode -- an in-place write silently voids every backup"
		)
	}

	/// Storing from a file leaves no debris beside the finding it stored. The sibling the swap uses
	/// is not canonical, and the orphan sweep would delete it -- but only later, and only if it ran.
	func testSaveCopyingFrom_leavesNoStagedSiblingBehind() throws {
		let id = UUID()
		let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
		try Data(repeating: 0xE5, count: 1024).write(to: incoming)
		defer { try? FileManager.default.removeItem(at: incoming) }

		// Measured against what was already there: this suite shares the real Documents/Findings
		// directory, so the property is "one new file", not "one file".
		let before = Self.screenshotFilenames()
		let filename = try FindingScreenshotStore.save(copyingFrom: incoming, for: id, pathExtension: "jpg")
		defer { FindingScreenshotStore.delete(filename: filename) }

		XCTAssertEqual(
			Self.screenshotFilenames().subtracting(before), [filename],
			"the sibling the swap copies through must not survive the store"
		)
	}

	// MARK: - restore / undoInParent (AIA-0935)

	/// `restore` itself has no account or owner check — ownership is enforced on the public import
	/// path that produces the backup tuple. Covered below via ``ImportRejection``.
	func testRestore_nilBackup_returnsImmediately() {
		sut.restore(nil)
		// No crash, no file IO: a nil argument is the "nothing to put back" branch.
	}

	func testRestore_missingBackupURL_deletesDestinationFilename() throws {
		let id = UUID()
		let original = Data(repeating: 0x11, count: 512)
		let filename = try FindingScreenshotStore.save(original, for: id, pathExtension: "jpg")
		defer { FindingScreenshotStore.delete(filename: filename) }

		XCTAssertNotNil(FindingScreenshotStore.url(forFilename: filename).flatMap {
			FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
		})

		// Nil backup URL means "there was nothing here" — delete whatever is at that name.
		sut.restore((filename: filename, backup: nil))

		let destination = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: destination.path),
			"a missing backup must clear the destination filename"
		)
	}

	func testRestore_backupFile_restoresDestinationAndSurvivesASecondRestore() throws {
		let id = UUID()
		let original = Data(repeating: 0x22, count: 1024)
		let replaced = Data(repeating: 0x33, count: 2048)
		let filename = try FindingScreenshotStore.save(original, for: id, pathExtension: "jpg")
		let destination = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))

		let backupDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("FindingRestore-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
		let backupURL = backupDirectory.appendingPathComponent(filename)
		try FileManager.default.linkItem(at: destination, to: backupURL)
		defer {
			try? FileManager.default.removeItem(at: backupDirectory)
			FindingScreenshotStore.delete(filename: filename)
		}

		// Simulate the import writing a new picture over the destination.
		_ = try FindingScreenshotStore.save(replaced, for: id, pathExtension: "jpg")
		XCTAssertEqual(try Data(contentsOf: destination), replaced)

		sut.restore((filename: filename, backup: backupURL))
		XCTAssertEqual(try Data(contentsOf: destination), original, "first restore puts the backup back")
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: backupURL.path),
			"the backup must survive the first restore so a second rollback can use it"
		)

		_ = try FindingScreenshotStore.save(replaced, for: id, pathExtension: "jpg")
		sut.restore((filename: filename, backup: backupURL))
		XCTAssertEqual(try Data(contentsOf: destination), original, "a second restore must still work")
	}

	func testUndoInParent_deletesCreated_refreshesReplaced_leavesUnrelatedPending() throws {
		let replacedId = UUID()
		let createdId = UUID()
		let unrelatedId = UUID()

		let replaced = Finding.create(in: moc)
		replaced.entityId = replacedId
		replaced.title = "Stored title"
		replaced.creationDate_ = .now
		replaced.screenshotFilename = Finding.screenshotFilename(for: replacedId)
		replaced.boxX = 0.1
		replaced.boxY = 0.1
		replaced.boxWidth = 0.2
		replaced.boxHeight = 0.2
		replaced.detectionConfidence = 0.5
		replaced.transition(to: .draft)
		try replaced.throwIfInvalid()
		replaced.transition(to: .ready)
		try Finding.save(in: moc)

		replaced.title = "Unsaved edit"
		XCTAssertEqual(replaced.title, "Unsaved edit")

		let created = Finding.create(in: moc)
		created.entityId = createdId
		created.title = "Created pending"
		created.creationDate_ = .now
		created.screenshotFilename = Finding.screenshotFilename(for: createdId)
		created.boxX = 0.1
		created.boxY = 0.1
		created.boxWidth = 0.2
		created.boxHeight = 0.2
		created.detectionConfidence = 0.5
		created.transition(to: .draft)
		try created.throwIfInvalid()
		created.transition(to: .ready)

		let unrelated = Finding.create(in: moc)
		unrelated.entityId = unrelatedId
		unrelated.title = "Unrelated pending"
		unrelated.creationDate_ = .now
		unrelated.screenshotFilename = Finding.screenshotFilename(for: unrelatedId)
		unrelated.boxX = 0.1
		unrelated.boxY = 0.1
		unrelated.boxWidth = 0.2
		unrelated.boxHeight = 0.2
		unrelated.detectionConfidence = 0.5
		unrelated.transition(to: .draft)
		try unrelated.throwIfInvalid()
		unrelated.transition(to: .ready)

		XCTAssertTrue(moc.insertedObjects.contains(created))
		XCTAssertTrue(moc.insertedObjects.contains(unrelated))
		XCTAssertTrue(moc.updatedObjects.contains(replaced) || replaced.hasChanges)

		sut.undoInParent(created: [createdId], replaced: [replacedId])

		XCTAssertNil(Finding.select(createdId, in: moc), "created ids are deleted in the parent")
		XCTAssertEqual(
			try XCTUnwrap(Finding.select(replacedId, in: moc)).title,
			"Stored title",
			"replaced ids lose unsaved edits (refresh mergeChanges: false)"
		)
		XCTAssertNotNil(
			Finding.select(unrelatedId, in: moc),
			"an unrelated pending insert must remain"
		)
		XCTAssertEqual(
			try XCTUnwrap(Finding.select(unrelatedId, in: moc)).title,
			"Unrelated pending"
		)

		// Drop the unrelated insert so tearDown does not leave it for an accidental later save.
		if let leftover = Finding.select(unrelatedId, in: moc) {
			moc.delete(leftover)
		}
		moc.rollback()
	}

	/// Wrong-archive rejection on the public import API. `restore` has no owner check of its own.
	func testImportFindings_invalidArchiveRow_isRejected() throws {
		let badId = UUID()
		let contents = FindingArchiveContents(
			rows: [
				ImportedFindingRow(
					id: badId,
					title: "",
					label: nil,
					note: nil,
					author: nil,
					gps: nil,
					page: URL(string: "https://example.com/bad"),
					detectionClass: nil,
					confidence: 0.5,
					creationDate: nil,
					box: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
					captureBox: nil,
					modifiedAt: nil,
					modelId: nil,
					lifeCycle: CoreDataManageableState.ready.rawValue,
					screenshotExtension: nil,
					source: nil,
					receivedAt: nil
				)
			],
			images: [:]
		)

		let summary = try sut.importFindings(contents, duplicates: .skip)
		XCTAssertEqual(summary.rejected, 1, "invalid archive content must be ImportRejection")
		XCTAssertEqual(summary.restored, 0)
		XCTAssertNil(Finding.select(badId, in: moc), "a rejected row must not persist")
	}
}
