//
//  ReceivedFindingImportTests.swift
//  MLBrowserUnitTests
//
//  AIA-0835: proves `FindingRepository.saveReceived` turns a share-link payload into a stored
//  `.received` finding — and pins the two conversions that are silently wrong if reversed.
//

import XCTest
import CoreData
@testable import ML_Browser

@MainActor
final class ReceivedFindingImportTests: XCTestCase {

	private var dataController: DataController!
	private var sut: FindingRepository!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		sut = FindingRepository(dataController: dataController)
	}

	override func tearDown() async throws {
		sut = nil
		dataController = nil
		try await super.tearDown()
	}

	private func payload(
		id: UUID? = UUID(),
		title: String = "Received find",
		box: FindingShareLink.Box? = nil,
		date: DateComponents? = nil,
		confidencePercent: Int? = nil,
		coordinate: FindingShareLink.Coordinate? = nil,
		author: String? = nil
	) -> FindingShareLink.Payload {
		FindingShareLink.Payload(
			id: id,
			title: title,
			detectionClass: "mound",
			confidencePercent: confidencePercent,
			coordinate: coordinate,
			box: box,
			page: URL(string: "https://ags.cuzk.cz/av/"),
			author: author,
			date: date
		)
	}

	// MARK: - The row it makes

	func testSaveReceived_StoresAReadyRowMarkedReceived() throws {
		let finding = try sut.saveReceived(payload(title: "  Trimmed  "))

		XCTAssertEqual(finding.source, .received)
		XCTAssertEqual(finding.lifeCycle, .ready, "a received finding must reach .ready or it lists nowhere")
		XCTAssertEqual(finding.title, "Trimmed")
		XCTAssertNotNil(finding.receivedAt)
	}

	/// The canonical name with no file behind it — the state archive import already produces. If
	/// validation ever starts touching the filesystem this fails, which is the point.
	func testSaveReceived_NamesAScreenshotItDoesNotWrite() throws {
		let finding = try sut.saveReceived(payload())

		let filename = try XCTUnwrap(finding.screenshotFilename)
		XCTAssertTrue(Finding.isCanonicalScreenshotFilename(filename, for: finding.entityId))
		let url = try XCTUnwrap(FindingScreenshotStore.url(forFilename: filename))
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: url.path),
			"the link carries no image; nothing may be written to disk for it"
		)
	}

	// MARK: - The box origin flip

	/// `FindingShareLink.Box` is top-left origin; `boxX…`/`captureBox…` are bottom-left Vision
	/// rects. A box at the TOP of the page must land at a HIGH y in Vision space.
	///
	/// Mutating `visionRect(fromWire:)` to assign `box.y` straight through flips this, and this
	/// assertion is what catches it — `y` and `1 - y - height` are deliberately different numbers
	/// here (0.1 vs 0.7), so a symmetric box could not make the test pass by accident.
	func testSaveReceived_ConvertsTheWireBoxIntoAVisionRect() throws {
		let wire = try XCTUnwrap(FindingShareLink.Box(x: 0.25, y: 0.1, width: 0.5, height: 0.2))
		let finding = try sut.saveReceived(payload(box: wire))

		XCTAssertEqual(finding.captureBoxX, 0.25, accuracy: 0.0001)
		XCTAssertEqual(finding.captureBoxY, 0.7, accuracy: 0.0001, "1 - 0.1 - 0.2 = 0.7")
		XCTAssertEqual(finding.captureBoxWidth, 0.5, accuracy: 0.0001)
		XCTAssertEqual(finding.captureBoxHeight, 0.2, accuracy: 0.0001)
	}

	/// A link with no box: `captureBox…` is the documented zero "not recorded" marker, while
	/// `boxX…` gets the unit rect because validation demands one and it has no absence signal.
	func testSaveReceived_WithNoBox_RecordsAbsenceInCaptureBoxAndStillValidates() throws {
		let finding = try sut.saveReceived(payload(box: nil))

		XCTAssertEqual(finding.captureBoxWidth, 0, "a zero captureBox is how 'no box was sent' is stored")
		XCTAssertEqual(finding.captureBoxHeight, 0)
		XCTAssertEqual(finding.boxWidth, 1, accuracy: 0.0001)
		XCTAssertEqual(finding.boxHeight, 1, accuracy: 0.0001)
		// The whole unit square, asserted as geometry rather than via validationReport(): saveReceived
		// throws on an invalid row, so "it validates" is true by construction and would pass whatever
		// the fallback did.
		XCTAssertEqual(finding.boxX, 0, accuracy: 0.0001)
		XCTAssertEqual(finding.boxY, 0, accuracy: 0.0001)
	}

	// MARK: - The UTC day

	/// The wire day is Gregorian/UTC on both sides. Resolving it in the recipient's calendar makes
	/// a link dated 2026-09-03 re-emit as 2026-09-02 for anyone east of UTC.
	func testSaveReceived_ResolvesTheLinkDayInUTC() throws {
		let finding = try sut.saveReceived(
			payload(date: DateComponents(year: 2026, month: 9, day: 3))
		)

		var utc = Calendar(identifier: .gregorian)
		utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
		let stored = try XCTUnwrap(finding.creationDate_)
		let parts = utc.dateComponents([.year, .month, .day], from: stored)
		XCTAssertEqual(parts.year, 2026)
		XCTAssertEqual(parts.month, 9)
		XCTAssertEqual(parts.day, 3, "the stored day must survive a UTC read-back unchanged")
	}

	/// A partial date is not a date: `Calendar` would happily fill in 1 January, which nobody sent.
	func testSaveReceived_WithAnIncompleteDate_FallsBackToTheReceiptInstant() throws {
		let finding = try sut.saveReceived(payload(date: DateComponents(year: 2026)))

		XCTAssertEqual(finding.creationDate_, finding.receivedAt)
	}

	func testSaveReceived_WithNoDate_FallsBackToTheReceiptInstant() throws {
		let finding = try sut.saveReceived(payload(date: nil))

		XCTAssertEqual(finding.creationDate_, finding.receivedAt)
	}

	// MARK: - Identity

	/// The id is a signature: a sender opening their own link must get their finding back, not a
	/// second copy of it.
	func testSaveReceived_WhenTheIdIsAlreadyStored_ReturnsTheExistingRowAndWritesNothing() throws {
		let shared = UUID()
		let first = try sut.saveReceived(payload(id: shared, title: "First"))
		let second = try sut.saveReceived(payload(id: shared, title: "Different title"))

		XCTAssertEqual(first.objectID, second.objectID)
		XCTAssertEqual(second.title, "First", "the stored copy must not be rewritten by a re-open")
		XCTAssertEqual(try count(), 1)
	}

	/// An id-less link is kept rather than refused — losing a real finding is worse than a
	/// duplicate — so two opens legitimately make two rows. Asserted so the cost is a decision on
	/// record rather than a surprise.
	func testSaveReceived_WithNoId_ImportsUnderAFreshIdEachTime() throws {
		let first = try sut.saveReceived(payload(id: nil))
		let second = try sut.saveReceived(payload(id: nil))

		XCTAssertNotEqual(first.entityId, second.entityId)
		XCTAssertEqual(try count(), 2)
	}

	// MARK: - Boundary values

	/// `Payload` validates nothing and can be constructed directly, so an out-of-range confidence
	/// must be clamped here — `throwIfInvalid` would otherwise reject the whole finding.
	func testSaveReceived_ClampsAnOutOfRangeConfidence() throws {
		let finding = try sut.saveReceived(payload(confidencePercent: 101))

		XCTAssertEqual(finding.detectionConfidence, 1, accuracy: 0.0001)
	}

	func testSaveReceived_StoresTheSendersAuthorVerbatim() throws {
		let finding = try sut.saveReceived(payload(author: "Someone Else"))

		XCTAssertEqual(finding.author, "Someone Else", "the sender keeps the credit on a forwarded find")
	}

	private func count() throws -> Int {
		try moc.count(for: Finding.fetchRequest())
	}
}

// MARK: - Provenance across the archive / sync wire

/// `FindingExporter.encodeJSON` → `FindingArchiveImport.decodeRows` is not only the file format:
/// it is the cloud-sync wire (`FindingsSyncCoordinator` uploads with the first and downloads with
/// the second). So these assertions cover both paths at once.
@MainActor
final class ReceivedFindingRoundTripTests: XCTestCase {

	private var dataController: DataController!
	private var sut: FindingRepository!

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		sut = FindingRepository(dataController: dataController)
	}

	override func tearDown() async throws {
		sut = nil
		dataController = nil
		try await super.tearDown()
	}

	private func encoded(_ snapshot: FindingSnapshot) throws -> [ImportedFindingRow] {
		let data = try FindingExporter.encodeJSON([snapshot], copiedImageNames: [:])
		return try FindingArchiveImport.decodeRows(data)
	}

	func testReceivedProvenanceSurvivesTheRoundTrip() throws {
		let received = Date(timeIntervalSince1970: 1_780_000_000)
		let rows = try encoded(
			FindingSnapshot(
				id: UUID(), title: "Forwarded",
				source: FindingSource.received.rawValue, receivedAt: received
			)
		)

		let row = try XCTUnwrap(rows.first)
		XCTAssertEqual(row.source, FindingSource.received.rawValue)
		XCTAssertEqual(row.receivedAt?.timeIntervalSince1970 ?? 0, received.timeIntervalSince1970, accuracy: 1)
	}

	/// A locally captured finding has never had `source_` written, so the wire says null — and a
	/// reader must take that as "the user's own", which is what nil reads as.
	/// Built from a real `Finding`, not from `FindingSnapshot`'s defaults: the earlier version of
	/// this test asserted that an unset parameter was nil, which is true whatever the code does.
	func testALocalFindingTravelsWithNoStatedProvenance() throws {
		let moc = dataController.container.viewContext
		let local = Finding.create(in: moc)
		local.entityId = UUID()
		local.title = "Mine"
		local.creationDate_ = .now
		local.boxX = 0; local.boxY = 0; local.boxWidth = 1; local.boxHeight = 1
		local.screenshotFilename = Finding.screenshotFilename(for: local.entityId)
		local.transition(to: .draft)
		local.transition(to: .ready)
		try Finding.save(in: moc)

		let rows = try encoded(FindingSnapshot(local))

		XCTAssertNil(try XCTUnwrap(rows.first).source, "a locally captured finding states no provenance")
		XCTAssertNil(try XCTUnwrap(rows.first).receivedAt)
	}

	/// An archive predating provenance decodes without the keys at all — the reason
	/// `schemaVersion` is deliberately NOT bumped for this change.
	func testAnArchiveWithoutTheKeysStillDecodes() throws {
		let json = Data("""
		{"schemaVersion":1,"findings":[{"id":"\(UUID().uuidString)","title":"Legacy",\
		"confidence":0,"box":{"x":0,"y":0,"width":0.1,"height":0.1},"lifeCycle":"ready"}]}
		""".utf8)

		let rows = try FindingArchiveImport.decodeRows(json)

		XCTAssertEqual(rows.count, 1, "adding optional keys must not break an older document")
		XCTAssertNil(rows[0].source)
	}

	/// **The provenance-reset guard.** Cloud sync replace-imports automatically, so a peer that
	/// does not know the field re-uploads the row with no `source`. If `apply` assigned that nil,
	/// every device would relabel a stranger's finding as the user's own — editable, and shown as
	/// theirs.
	///
	/// Mutate the harmful direction: replace the `if let` in `apply` with a bare assignment and
	/// this test must go red.
	func testReplaceImportWithoutProvenanceDoesNotResetAStoredReceivedRow() throws {
		let id = UUID()
		let stored = try sut.saveReceived(
			FindingShareLink.Payload(id: id, title: "From a stranger")
		)
		XCTAssertEqual(stored.source, .received)

		let silent = ImportedFindingRow(
			id: id, title: "From a stranger", label: nil, note: nil, author: nil, gps: nil,
			page: nil, detectionClass: nil, confidence: 0, creationDate: nil,
			box: .init(x: 0, y: 0, width: 1, height: 1), captureBox: nil, modifiedAt: nil,
			modelId: nil, lifeCycle: CoreDataManageableState.ready.rawValue,
			screenshotExtension: nil, source: nil, receivedAt: nil
		)
		let summary = try sut.importFindings(
			FindingArchiveContents(rows: [silent], images: [:]), duplicates: .replace
		)

		XCTAssertEqual(summary.restored, 1)
		let after = try XCTUnwrap(Finding.select(id, in: dataController.container.viewContext))
		XCTAssertEqual(
			after.source, .received,
			"a peer that never stated provenance must not be able to claim someone else's finding"
		)
	}
}
