//
//  FindingArchiveImportTests.swift
//  MLBrowserUnitTests
//
//  AIA-713 Phase 1: reading a findings export back.
//

import XCTest
import UIKit
import CoreData
@testable import ML_Browser

/// Builds real archives — via `NSFileCoordinator`, exactly as `FindingExporter` does — and imports
/// them. Nothing here hand-assembles zip bytes: the point of these tests is that the app can read
/// what the app writes, which a synthetic archive cannot demonstrate.
@MainActor
final class FindingArchiveImportTests: XCTestCase {

	private var dataController: DataController!
	private var sut: FindingRepository!
	private var scratch: URL!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		sut = FindingRepository(dataController: dataController)
		scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: scratch)
		// Leave no screenshots behind for the next test's store to adopt.
		FindingScreenshotStore.sweepOrphans(in: moc)
		sut = nil
		dataController = nil
		try await super.tearDown()
	}

	// MARK: - Archive construction (real zips, real exporter where possible)

	private func makeImage(_ side: Int = 12, color: UIColor = .darkGray) -> UIImage {
		UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
			color.setFill()
			ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
		}
	}

	/// Zips a `Findings/` directory the way `FindingExporter` does, so the archive has the same
	/// root entry and the same (deflated) compression.
	private func zip(findingsDirectory: URL) throws -> URL {
		let destination = scratch.appendingPathComponent("\(UUID().uuidString).zip")
		var coordinatorError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: findingsDirectory, options: .forUploading, error: &coordinatorError) { zipped in
			do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copyError = error }
		}
		if let coordinatorError { throw coordinatorError }
		if let copyError { throw copyError }
		return destination
	}

	/// Builds an archive from a literal manifest plus image bytes, for the cases a real export
	/// cannot produce (v0 archives, hostile paths).
	private func makeArchive(manifest: String, images: [String: Data] = [:]) throws -> URL {
		let root = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let findings = root.appendingPathComponent("Findings", isDirectory: true)
		let imagesDirectory = findings.appendingPathComponent("images", isDirectory: true)
		try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
		try Data(manifest.utf8).write(to: findings.appendingPathComponent("findings.json"))
		for (name, data) in images {
			try data.write(to: imagesDirectory.appendingPathComponent(name))
		}
		return try zip(findingsDirectory: findings)
	}

	/// Saves a finding through the production path, so the archive under test comes from real rows.
	@discardableResult
	private func saveFinding(title: String, note: String = "") throws -> Finding {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let capture = FindingCapture(
			observation: DetectedObject(uuid: UUID(), labels: [], confidence: 0.9, boundingBox: box, regionIndex: 0),
			params: nil,
			frame: AppliedDetectionFrame(image: makeImage(), results: []),
			pageURL: URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
		)
		return try sut.save(
			capture: capture,
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: title, label: "", note: note, author: "", gps: "")
		)
	}

	private func exportEverything() throws -> URL {
		let snapshots = sut.allFindingSnapshots()
		return try FindingExporter.makeZip(from: snapshots)
	}

	private func importArchive(_ url: URL, duplicates: FindingRepository.DuplicatePolicy = .skip) throws -> FindingRepository.ImportSummary {
		let contents = try FindingArchiveImport.read(archiveAt: url)
		return try sut.importFindings(contents, duplicates: duplicates)
	}

	/// Empties the store row by row, deleting each screenshot with it.
	///
	/// Deliberately NOT `FindingRepository.removeAllFindings()`, which issues an
	/// `NSBatchDeleteRequest`: ios/AGENTS.md §6 records that batch operations do not work against
	/// `NSInMemoryStoreType`, and the attempt raises `NSInternalInconsistencyException` rather than
	/// failing an assertion. This wipe is equivalent for the round trip's purposes — no rows, no
	/// files — without dragging a SQLite store into a test about archives.
	private func wipeStore() throws {
		for finding in Finding.selectAll(in: moc) {
			FindingScreenshotStore.delete(filename: finding.screenshotFilename)
			moc.delete(finding)
		}
		try Finding.save(in: moc)
	}

	// MARK: - The round trip this phase exists for

	/// Export, wipe, import: every field and the image bytes come back. Uses the REAL exporter, so
	/// a change to either side that breaks the pair fails here.
	func testRoundTrip_exportThenWipeThenImport_restoresFindingsAndImageBytes() throws {
		try saveFinding(title: "Ringfort", note: "north slope")
		try saveFinding(title: "Burial mound")
		let before = sut.allFindingSnapshots().sorted { $0.title < $1.title }
		let imageBytes = try before.map { try Data(contentsOf: XCTUnwrap($0.screenshotSourceURL)) }

		let archive = try exportEverything()
		try wipeStore()
		XCTAssertFalse(sut.hasAnyFinding(), "precondition: the store is empty before importing")

		let summary = try importArchive(archive)
		XCTAssertEqual(summary, .init(restored: 2, skipped: 0, failed: 0))

		let after = sut.allFindingSnapshots().sorted { $0.title < $1.title }
		XCTAssertEqual(after.map(\.id), before.map(\.id), "identity must survive the round trip")
		XCTAssertEqual(after.map(\.title), before.map(\.title))
		XCTAssertEqual(after.map(\.note), before.map(\.note))
		XCTAssertEqual(after.map(\.box), before.map(\.box))
		XCTAssertEqual(after.map(\.page), before.map(\.page))

		let restoredBytes = try after.map { try Data(contentsOf: XCTUnwrap($0.screenshotSourceURL)) }
		XCTAssertEqual(restoredBytes, imageBytes, "images must be byte-identical, not re-encoded")
	}

	/// The bare top-level array 1.0.7 shipped. Those archives must import for ever.
	func testImport_v0BareArrayArchive_restores() throws {
		let id = UUID()
		let manifest = """
		[{"id":"\(id.uuidString)","title":"Legacy hillfort","label":null,"note":null,"author":null,\
		"gps":null,"page":"https://example.com/a","detectionClass":null,"confidence":0.5,\
		"date":"2026-01-02T03:04:05Z","box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},"screenshot":null}]
		"""
		let summary = try importArchive(try makeArchive(manifest: manifest))

		XCTAssertEqual(summary.restored, 1)
		let restored = try XCTUnwrap(Finding.select(id, in: moc))
		XCTAssertEqual(restored.title, "Legacy hillfort")
		XCTAssertEqual(restored.lifeCycle, .ready, "a v0 row carries no lifeCycle and restores as ready")
	}

	// MARK: - The capture-space box on the wire (AIA-0761)

	/// A one-row v1 archive whose `captureBox` entry is spelled by the caller — including not being
	/// spelled at all, which is a case in its own right.
	private func makeCaptureBoxArchive(id: UUID, captureBoxJSON: String) throws -> URL {
		try makeArchive(manifest: """
		{"schemaVersion":1,"findings":[{"id":"\(id.uuidString)","title":"Boxed","label":null,\
		"note":null,"author":null,"gps":null,"page":"https://example.com/a","detectionClass":null,\
		"confidence":0.5,"date":null,"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},\
		\(captureBoxJSON)"modifiedAt":null,"modelId":null,"lifeCycle":"ready","screenshot":null}]}
		""")
	}

	/// The field has to survive the wire verbatim: after a crop it is the only rectangle a share
	/// link can honestly state, and a restored finding that lost it emits no box at all.
	func testRead_statedCaptureBox_decodesOntoTheRow() throws {
		let archive = try makeCaptureBoxArchive(
			id: UUID(),
			captureBoxJSON: "\"captureBox\":{\"x\":0.2,\"y\":0.1,\"width\":0.3,\"height\":0.2},"
		)
		let row = try XCTUnwrap(FindingArchiveImport.read(archiveAt: archive).rows.first)

		XCTAssertEqual(row.captureBox, .init(x: 0.2, y: 0.1, width: 0.3, height: 0.2))
	}

	/// Both spellings of "this archive says nothing about a capture box": the key missing entirely
	/// (an archive written before the field existed) and an explicit null (a device that has none).
	/// They must decode alike, because the caller reads nil as "keep whatever is local" — reading an
	/// omission as anything else would let an old peer's export blank a box this device knows.
	func testRead_omittedOrNullCaptureBox_decodesAsNotStated() throws {
		for captureBoxJSON in ["", "\"captureBox\":null,"] {
			let archive = try makeCaptureBoxArchive(id: UUID(), captureBoxJSON: captureBoxJSON)
			let row = try XCTUnwrap(FindingArchiveImport.read(archiveAt: archive).rows.first)

			XCTAssertNil(row.captureBox, "captureBox JSON '\(captureBoxJSON)' should decode as not stated")
		}
	}

	/// A malformed capture box costs the field, never the finding. `FindingRepository.apply` turns
	/// any validation failure into `ImportRejection.invalidContent`, which cloud sync never retries —
	/// far too high a price for a rectangle no renderer requires. So it is sanitized to "not stated"
	/// at the boundary and the row still lands.
	func testRead_malformedCaptureBox_isSanitizedToNotStatedAndTheRowSurvives() throws {
		let malformed = [
			"\"captureBox\":{\"x\":0.9,\"y\":0.9,\"width\":0.5,\"height\":0.5},",
			"\"captureBox\":{\"x\":-0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2},",
			"\"captureBox\":{\"x\":0.1,\"y\":0.1,\"width\":0,\"height\":0},"
		]
		for captureBoxJSON in malformed {
			let id = UUID()
			let archive = try makeCaptureBoxArchive(id: id, captureBoxJSON: captureBoxJSON)
			let rows = try FindingArchiveImport.read(archiveAt: archive).rows

			XCTAssertEqual(rows.count, 1, "'\(captureBoxJSON)' must not cost the finding")
			XCTAssertNil(try XCTUnwrap(rows.first).captureBox, "'\(captureBoxJSON)' should be sanitized away")

			let summary = try importArchive(archive)
			XCTAssertEqual(summary.restored, 1, "'\(captureBoxJSON)' must still restore the row")
			XCTAssertEqual(
				try XCTUnwrap(Finding.select(id, in: moc)).captureNormalizedBox, .zero,
				"nothing was stated, so the row keeps the zero rect that means 'never recorded'"
			)
		}
	}

	/// Identity is resolved BEFORE any file is written. A skipped duplicate must leave the stored
	/// finding's image untouched — the filename derives from the id, so writing first would
	/// overwrite a picture the user never agreed to change.
	func testSkippedDuplicate_leavesTheStoredImageByteIdentical() throws {
		let finding = try saveFinding(title: "Original")
		let url = try XCTUnwrap(FindingScreenshotStore.url(forFilename: XCTUnwrap(finding.screenshotFilename)))
		let originalBytes = try Data(contentsOf: url)

		// An archive carrying the SAME id but a different picture.
		let archive = try makeArchive(
			manifest: """
			{"schemaVersion":1,"findings":[{"id":"\(finding.entityId.uuidString)","title":"Impostor",\
			"label":null,"note":null,"author":null,"gps":null,"page":"https://example.com/b",\
			"detectionClass":null,"confidence":0.5,"date":null,\
			"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},"modifiedAt":null,"modelId":null,\
			"lifeCycle":"ready","screenshot":"images/\(finding.entityId.uuidString).jpg"}]}
			""",
			images: ["\(finding.entityId.uuidString).jpg": try XCTUnwrap(makeImage(40, color: .red).jpegData(compressionQuality: 0.7))]
		)

		let summary = try importArchive(archive, duplicates: .skip)
		XCTAssertEqual(summary, .init(restored: 0, skipped: 1, failed: 0))
		XCTAssertEqual(try Data(contentsOf: url), originalBytes, "a skipped duplicate must not write over the stored image")
		XCTAssertEqual(finding.title, "Original", "nor change the row")
	}

	func testReplacePolicy_overwritesTheStoredFinding() throws {
		let finding = try saveFinding(title: "Original")
		let archive = try makeArchive(manifest: """
		{"schemaVersion":1,"findings":[{"id":"\(finding.entityId.uuidString)","title":"Replaced",\
		"label":null,"note":null,"author":null,"gps":null,"page":"https://example.com/b",\
		"detectionClass":null,"confidence":0.5,"date":null,\
		"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},"modifiedAt":null,"modelId":null,\
		"lifeCycle":"ready","screenshot":null}]}
		""")

		let summary = try importArchive(archive, duplicates: .replace)
		XCTAssertEqual(summary, .init(restored: 1, skipped: 0, failed: 0))
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1, "replace must not create a second copy")
		XCTAssertEqual(try XCTUnwrap(Finding.select(finding.entityId, in: moc)).title, "Replaced")
	}

	/// One row must not be able to claim another row's image, and a traversal path must not be
	/// accepted at all. Both are refused by requiring the canonical `images/<own-id>.<ext>`.
	func testImport_screenshotPathThatIsNotTheRowsOwn_isRejected() throws {
		let mine = UUID()
		let someoneElse = UUID()
		for path in ["images/\(someoneElse.uuidString).jpg", "../../etc/passwd", "images/../../secret.jpg"] {
			let archive = try makeArchive(manifest: """
			{"schemaVersion":1,"findings":[{"id":"\(mine.uuidString)","title":"Greedy","label":null,\
			"note":null,"author":null,"gps":null,"page":"https://example.com/a","detectionClass":null,\
			"confidence":0.5,"date":null,"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},\
			"modifiedAt":null,"modelId":null,"lifeCycle":"ready","screenshot":"\(path)"}]}
			""")
			XCTAssertThrowsError(try FindingArchiveImport.read(archiveAt: archive), "accepted '\(path)'") { error in
				guard case .malformedManifest = error as? FindingArchiveImportError else {
					return XCTFail("expected .malformedManifest for '\(path)', got \(error)")
				}
			}
			XCTAssertEqual(Finding.count(in: moc, predicate: nil), 0, "a refused archive writes nothing")
		}
	}

	/// The archived timestamp is authoritative. Stamping "now" would make a restored copy beat a
	/// newer edit elsewhere under last-write-wins.
	func testImport_preservesTheArchivedModifiedAt() throws {
		let id = UUID()
		let archived = "2020-05-06T07:08:09.250Z"
		let archive = try makeArchive(manifest: """
		{"schemaVersion":1,"findings":[{"id":"\(id.uuidString)","title":"Old edit","label":null,\
		"note":null,"author":null,"gps":null,"page":"https://example.com/a","detectionClass":null,\
		"confidence":0.5,"date":null,"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},\
		"modifiedAt":"\(archived)","modelId":null,"lifeCycle":"ready","screenshot":null}]}
		""")

		XCTAssertEqual(try importArchive(archive).restored, 1)
		let restored = try XCTUnwrap(Finding.select(id, in: moc))
		let expected = try XCTUnwrap({ () -> Date? in
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			return formatter.date(from: archived)
		}())
		XCTAssertEqual(
			try XCTUnwrap(restored.modifiedAt).timeIntervalSince1970,
			expected.timeIntervalSince1970,
			accuracy: 0.001,
			"willSave must not overwrite an import's authoritative timestamp"
		)
	}

	/// A row that cannot be valid must not land as `.ready`, and must not take the rest of the
	/// import down with it — `Finding.save(in:)` commits the whole context.
	///
	/// Counted as `rejected`, not `failed`. The two are kept apart because sync retries a page: a
	/// row whose own content is invalid reproduces the same refusal every time, so counting it as a
	/// failure pinned the cursor on it and lost every finding behind it (AIA-0752).
	func testImport_invalidRowIsCountedRejected_andTheValidOnesStillLand() throws {
		let good = UUID()
		let bad = UUID()
		let archive = try makeArchive(manifest: """
		{"schemaVersion":1,"findings":[\
		{"id":"\(good.uuidString)","title":"Good","label":null,"note":null,"author":null,"gps":null,\
		"page":"https://example.com/a","detectionClass":null,"confidence":0.5,"date":null,\
		"box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2},"modifiedAt":null,"modelId":null,\
		"lifeCycle":"ready","screenshot":null},\
		{"id":"\(bad.uuidString)","title":"","label":null,"note":null,"author":null,"gps":null,\
		"page":"file:///etc/passwd","detectionClass":null,"confidence":9.9,"date":null,\
		"box":{"x":5,"y":5,"width":5,"height":5},"modifiedAt":null,"modelId":null,\
		"lifeCycle":"ready","screenshot":null}]}
		""")

		let summary = try importArchive(archive)
		XCTAssertEqual(summary.restored, 1)
		XCTAssertEqual(summary.rejected, 1, "invalid content is a rejection, which a retry cannot cure")
		XCTAssertEqual(summary.failed, 0, "nothing about this device failed")
		XCTAssertNotNil(Finding.select(good, in: moc), "the valid row must survive its bad neighbour")
		XCTAssertNil(Finding.select(bad, in: moc), "the invalid row must not be persisted")
	}

	func testImport_bytesThatAreNotAZip_areReportedNotCrashed() throws {
		let notAZip = scratch.appendingPathComponent("junk.zip")
		try Data("definitely not a zip".utf8).write(to: notAZip)
		XCTAssertThrowsError(try FindingArchiveImport.read(archiveAt: notAZip)) { error in
			guard case .unreadableArchive = error as? FindingArchiveImportError else {
				return XCTFail("expected .unreadableArchive, got \(error)")
			}
		}
	}
}
