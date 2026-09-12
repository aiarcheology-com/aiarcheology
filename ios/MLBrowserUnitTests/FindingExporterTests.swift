//
//  FindingExporterTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import XCTest
import UIKit
@testable import ML_Browser

/// Gate tests for the findings export (AIA-0287). The ZIP structure is verified
/// by parsing the archive's central directory in-process — no `Process`/`unzip`,
/// which is unavailable in the test sandbox. The JSON/CSV shape is verified
/// against the pure encoders directly (the zip stores them deflated).
final class FindingExporterTests: XCTestCase {
	private var scratch: URL!

	override func setUpWithError() throws {
		scratch = FileManager.default.temporaryDirectory
			.appendingPathComponent("FindingExporterTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: scratch)
	}

	// MARK: - ZIP structure gates

	func testMakeZip_mixedImages_containsJsonCsvAndOnlyPresentImages() throws {
		let present = snapshot(withImage: true)
		let missing = snapshot(withImage: false)

		let names = try entryNames(of: FindingExporter.makeZip(from: [present, missing]))

		XCTAssertTrue(names.contains("Findings/findings.json"))
		XCTAssertTrue(names.contains("Findings/findings.csv"))
		XCTAssertTrue(names.contains("Findings/images/\(present.id.uuidString).png"))
		XCTAssertFalse(names.contains("Findings/images/\(missing.id.uuidString).png"))
	}

	func testMakeZip_allImagesMissing_producesJsonCsvNoImages() throws {
		let names = try entryNames(of: FindingExporter.makeZip(from: [snapshot(withImage: false), snapshot(withImage: false)]))

		XCTAssertTrue(names.contains("Findings/findings.json"))
		XCTAssertTrue(names.contains("Findings/findings.csv"))
		XCTAssertFalse(names.contains { $0.hasSuffix(".png") })
	}

	func testMakeZip_zeroFindings_producesJsonAndCsv() throws {
		let names = try entryNames(of: FindingExporter.makeZip(from: []))

		XCTAssertTrue(names.contains("Findings/findings.json"))
		XCTAssertTrue(names.contains("Findings/findings.csv"))
		XCTAssertFalse(names.contains { $0.hasSuffix(".png") })
	}

	// MARK: - JSON shape

	func testEncodeJSON_zeroFindings_isEmptyFindingsArray() throws {
		let data = try FindingExporter.encodeJSON([], copiedImageNames: [:])
		let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(document["schemaVersion"] as? Int, 1)
		XCTAssertEqual((document["findings"] as? [Any])?.count, 0)
	}

	/// The envelope is what makes the archive self-describing; an importer that cannot tell
	/// v0 (bare array) from v1 has to guess, and guessing on user data is how findings get lost.
	func testEncodeJSON_wrapsRowsInASchemaVersionedEnvelope() throws {
		let data = try FindingExporter.encodeJSON(
			[FindingSnapshot(id: UUID(), title: "Enveloped")],
			copiedImageNames: [:]
		)
		let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(document["schemaVersion"] as? Int, FindingExporter.schemaVersion)
		let rows = try XCTUnwrap(document["findings"] as? [[String: Any]])
		XCTAssertEqual(rows.count, 1)
		XCTAssertEqual(rows.first?["title"] as? String, "Enveloped")
	}

	/// AIA-713: a restored finding must keep its provenance and its lifecycle, and carry the
	/// last-write-wins key at sub-second precision so two edits in the same second cannot tie.
	func testEncodeJSON_carriesModifiedAtModelIdAndLifeCycle() throws {
		let modelId = UUID()
		let snap = FindingSnapshot(
			id: UUID(),
			title: "Provenanced",
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
			modelId: modelId,
			lifeCycle: CoreDataManageableState.draft.rawValue
		)
		let data = try FindingExporter.encodeJSON([snap], copiedImageNames: [:])
		let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let row = try XCTUnwrap((document["findings"] as? [[String: Any]])?.first)

		XCTAssertEqual(row["modelId"] as? String, modelId.uuidString)
		XCTAssertEqual(row["lifeCycle"] as? String, CoreDataManageableState.draft.rawValue)
		let modifiedAt = try XCTUnwrap(row["modifiedAt"] as? String)
		XCTAssertTrue(
			modifiedAt.contains(".25") || modifiedAt.contains(".250"),
			"modifiedAt must serialize with fractional seconds, got \(modifiedAt)"
		)
	}

	func testEncodeJSON_nilOptionals_writesExplicitNulls() throws {
		// A present row whose every optional field is nil: the keys must still be
		// there, as JSON null — not omitted.
		let snap = FindingSnapshot(id: UUID(), box: .init(x: 0, y: 0, width: 0.1, height: 0.1))

		let data = try FindingExporter.encodeJSON([snap], copiedImageNames: [:])
		let rows = try XCTUnwrap(Self.findingRows(in: data))
		let row = try XCTUnwrap(rows.first)

		XCTAssertEqual(row["id"] as? String, snap.id.uuidString)
		for key in ["label", "note", "gps", "page", "detectionClass", "date", "screenshot", "modifiedAt", "modelId", "captureBox"] {
			XCTAssertTrue(row[key] is NSNull, "\(key) should serialize as explicit null")
		}
	}

	/// AIA-0761: the reader treats an absent `captureBox` as "not stated" and keeps its local value,
	/// so an export that omitted the key would be indistinguishable from an old client's archive and
	/// could never clear or correct anything. Null says "the sender has none"; omission says nothing
	/// at all, and this file's policy is null.
	func testEncodeJSON_captureBox_isExplicitNullWhenAbsentAndWrittenWhenPresent() throws {
		let recorded = FindingSnapshot(
			id: UUID(),
			title: "Recorded",
			captureBox: .init(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
		)
		let legacy = FindingSnapshot(id: UUID(), title: "Legacy")

		let data = try FindingExporter.encodeJSON([recorded, legacy], copiedImageNames: [:])
		let rows = try XCTUnwrap(Self.findingRows(in: data))

		let box = try XCTUnwrap(rows[0]["captureBox"] as? [String: Any])
		XCTAssertEqual(box["x"] as? Double, 0.2)
		XCTAssertEqual(box["y"] as? Double, 0.1)
		XCTAssertEqual(box["width"] as? Double, 0.3)
		XCTAssertEqual(box["height"] as? Double, 0.2)
		XCTAssertTrue(rows[1]["captureBox"] is NSNull, "captureBox should serialize as explicit null, not be omitted")
	}

	func testEncodeJSON_screenshotPath_presentOnlyWhenCopied() throws {
		let copied = FindingSnapshot(id: UUID())
		let notCopied = FindingSnapshot(id: UUID())

		let data = try FindingExporter.encodeJSON([copied, notCopied], copiedImageNames: [copied.id: "\(copied.id.uuidString).jpg"])
		let rows = try XCTUnwrap(Self.findingRows(in: data))

		XCTAssertEqual(rows[0]["screenshot"] as? String, "images/\(copied.id.uuidString).jpg")
		XCTAssertTrue(rows[1]["screenshot"] is NSNull)
	}

	func testEncodeJSON_includesTitle() throws {
		let snap = FindingSnapshot(id: UUID(), title: "Old Fort")
		let data = try FindingExporter.encodeJSON([snap], copiedImageNames: [:])
		let rows = try XCTUnwrap(Self.findingRows(in: data))
		XCTAssertEqual(rows.first?["title"] as? String, "Old Fort")
	}

	/// AIA-0651: the credit has to reach the export, and a finding saved without one must still
	/// carry the key — an importer distinguishing "no author" from "column absent" depends on it.
	func testEncodeJSON_author_isPresentWhenSetAndExplicitNullWhenAbsent() throws {
		let credited = FindingSnapshot(id: UUID(), title: "Signed", author: "Jane Archeologist")
		let anonymous = FindingSnapshot(id: UUID(), title: "Unsigned")

		let data = try FindingExporter.encodeJSON([credited, anonymous], copiedImageNames: [:])
		let rows = try XCTUnwrap(Self.findingRows(in: data))

		XCTAssertEqual(rows[0]["author"] as? String, "Jane Archeologist")
		XCTAssertTrue(rows[1]["author"] is NSNull, "author should serialize as explicit null, not be omitted")
	}

	/// Decodes the `findings` array out of the schemaVersion envelope.
	private static func findingRows(in data: Data) -> [[String: Any]]? {
		(try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["findings"] as? [[String: Any]]
	}

	// MARK: - CSV escaping

	func testCsvField_escapesCommaQuoteAndNewlines() {
		XCTAssertEqual(FindingExporter.csvField("plain"), "plain")
		XCTAssertEqual(FindingExporter.csvField("a,b"), "\"a,b\"")
		XCTAssertEqual(FindingExporter.csvField("a \"b\", c\r\nd"), "\"a \"\"b\"\", c\r\nd\"")
		XCTAssertEqual(FindingExporter.csvField(nil), "")
	}

	func testEncodeCSV_headerThenRows_nilFieldsAreEmpty() throws {
		let csv = FindingExporter.encodeCSV([FindingSnapshot(id: UUID())], copiedImageNames: [:])
		let lines = csv.components(separatedBy: "\r\n")

		XCTAssertEqual(lines.count, 2, "header + one row")
		XCTAssertTrue(lines[0].hasPrefix("id,title,label,note,gps,page,detectionClass,confidence,date,boxX,boxY,boxWidth,boxHeight,screenshot,author"))
		// title defaults to empty here, and label/note/gps/page/detectionClass/date/screenshot/author
		// are nil → empty cells.
		let cells = lines[1].components(separatedBy: ",")
		// `csvColumns` and the `fields` array are positionally coupled with nothing enforcing it;
		// one cell per declared column is the cheapest check that they did not drift apart.
		XCTAssertEqual(cells.count, lines[0].components(separatedBy: ",").count, "one cell per declared column")
		XCTAssertEqual(cells[1], "", "title cell empty")

		// Located by HEADER, never by `.last` or a literal index: `author` stopped being the final
		// column when AIA-713 appended modifiedAt/modelId/lifeCycle, which is the same way this
		// assertion broke when `author` itself was appended. Header lookup shifts with the schema.
		let header = lines[0].components(separatedBy: ",")
		func cell(_ column: String) throws -> String {
			let index = try XCTUnwrap(header.firstIndex(of: column), "no \(column) column")
			return cells[index]
		}
		XCTAssertEqual(try cell("screenshot"), "", "screenshot cell empty")
		XCTAssertEqual(try cell("author"), "", "author cell empty")
		XCTAssertEqual(try cell("modifiedAt"), "", "modifiedAt cell empty")
		XCTAssertEqual(try cell("modelId"), "", "modelId cell empty")
		// lifeCycle is NOT nullable — a restored finding has to land in a real state.
		XCTAssertEqual(try cell("lifeCycle"), CoreDataManageableState.ready.rawValue)
	}

	/// The author value lands in the cell the `author` HEADER names (AIA-0651). Located by header
	/// index rather than a hard-coded position or `.last`, so appending a column later shifts the
	/// lookup with it instead of quietly reading the neighbouring field.
	func testEncodeCSV_authorCell_matchesTheAuthorHeaderColumn() throws {
		let snapshot = FindingSnapshot(id: UUID(), title: "Signed", author: "Jane Archeologist")

		let csv = FindingExporter.encodeCSV([snapshot], copiedImageNames: [:])
		let lines = csv.components(separatedBy: "\r\n")
		let headers = try XCTUnwrap(lines.first).components(separatedBy: ",")
		let authorColumn = try XCTUnwrap(headers.firstIndex(of: "author"), "the CSV header declares no author column")
		let cells = lines[1].components(separatedBy: ",")

		XCTAssertEqual(cells.count, headers.count, "one cell per declared column")
		XCTAssertEqual(cells[authorColumn], "Jane Archeologist")
	}

	// MARK: - Helpers

	/// A snapshot whose `screenshotSourceURL` points to a real temp PNG (present)
	/// or to nil (so the copy is skipped — the missing-image path).
	private func snapshot(withImage: Bool) -> FindingSnapshot {
		let id = UUID()
		var source: URL?
		if withImage {
			source = scratch.appendingPathComponent("\(id.uuidString).png")
			try? pngData().write(to: source!)
		}
		return FindingSnapshot(
			id: id,
			box: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			screenshotSourceURL: source
		)
	}

	private func pngData() -> Data {
		let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
		let image = renderer.image { context in
			UIColor.red.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
		}
		return image.pngData() ?? Data()
	}

	/// Filenames in a zip's central directory. Reads the End Of Central Directory
	/// record, then walks each central-directory header — enough to assert the
	/// archive's layout without decompressing entry contents.
	private func entryNames(of url: URL) throws -> [String] {
		let bytes = [UInt8](try Data(contentsOf: url))
		func u16(_ offset: Int) -> Int {
			let b0 = Int(bytes[offset])
			let b1 = Int(bytes[offset + 1]) << 8
			return b0 | b1
		}
		func u32(_ offset: Int) -> Int {
			let b0 = Int(bytes[offset])
			let b1 = Int(bytes[offset + 1]) << 8
			let b2 = Int(bytes[offset + 2]) << 16
			let b3 = Int(bytes[offset + 3]) << 24
			return b0 | b1 | b2 | b3
		}

		let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
		var eocd = bytes.count - eocdSignature.count
		while eocd >= 0, Array(bytes[eocd..<eocd + 4]) != eocdSignature { eocd -= 1 }
		guard eocd >= 0 else { return [] }

		let totalEntries = u16(eocd + 10)
		var offset = u32(eocd + 16)
		let centralHeaderSignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
		var names: [String] = []
		for _ in 0..<totalEntries {
			guard offset + 46 <= bytes.count, Array(bytes[offset..<offset + 4]) == centralHeaderSignature else { break }
			let nameLength = u16(offset + 28)
			let extraLength = u16(offset + 30)
			let commentLength = u16(offset + 32)
			let nameStart = offset + 46
			guard nameStart + nameLength <= bytes.count else { break }
			names.append(String(bytes: bytes[nameStart..<nameStart + nameLength], encoding: .utf8) ?? "")
			offset = nameStart + nameLength + extraLength + commentLength
		}
		return names
	}
}
