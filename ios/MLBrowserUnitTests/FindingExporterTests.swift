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

	func testEncodeJSON_zeroFindings_isEmptyArray() throws {
		let data = try FindingExporter.encodeJSON([], copiedIds: [])
		let array = try JSONSerialization.jsonObject(with: data) as? [Any]
		XCTAssertEqual(array?.count, 0)
	}

	func testEncodeJSON_nilOptionals_writesExplicitNulls() throws {
		// A present row whose every optional field is nil: the keys must still be
		// there, as JSON null — not omitted.
		let snap = FindingSnapshot(id: UUID(), box: .init(x: 0, y: 0, width: 0.1, height: 0.1))

		let data = try FindingExporter.encodeJSON([snap], copiedIds: [])
		let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
		let row = try XCTUnwrap(rows.first)

		XCTAssertEqual(row["id"] as? String, snap.id.uuidString)
		for key in ["label", "note", "gps", "page", "detectionClass", "date", "screenshot"] {
			XCTAssertTrue(row[key] is NSNull, "\(key) should serialize as explicit null")
		}
	}

	func testEncodeJSON_screenshotPath_presentOnlyWhenCopied() throws {
		let copied = FindingSnapshot(id: UUID())
		let notCopied = FindingSnapshot(id: UUID())

		let data = try FindingExporter.encodeJSON([copied, notCopied], copiedIds: [copied.id])
		let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

		XCTAssertEqual(rows[0]["screenshot"] as? String, "images/\(copied.id.uuidString).png")
		XCTAssertTrue(rows[1]["screenshot"] is NSNull)
	}

	func testEncodeJSON_includesTitle() throws {
		let snap = FindingSnapshot(id: UUID(), title: "Old Fort")
		let data = try FindingExporter.encodeJSON([snap], copiedIds: [])
		let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
		XCTAssertEqual(rows.first?["title"] as? String, "Old Fort")
	}

	// MARK: - CSV escaping

	func testCsvField_escapesCommaQuoteAndNewlines() {
		XCTAssertEqual(FindingExporter.csvField("plain"), "plain")
		XCTAssertEqual(FindingExporter.csvField("a,b"), "\"a,b\"")
		XCTAssertEqual(FindingExporter.csvField("a \"b\", c\r\nd"), "\"a \"\"b\"\", c\r\nd\"")
		XCTAssertEqual(FindingExporter.csvField(nil), "")
	}

	func testEncodeCSV_headerThenRows_nilFieldsAreEmpty() {
		let csv = FindingExporter.encodeCSV([FindingSnapshot(id: UUID())], copiedIds: [])
		let lines = csv.components(separatedBy: "\r\n")

		XCTAssertEqual(lines.count, 2, "header + one row")
		XCTAssertTrue(lines[0].hasPrefix("id,title,label,note,gps,page,detectionClass,confidence,date,boxX,boxY,boxWidth,boxHeight,screenshot"))
		// title defaults to empty here, and label/note/gps/page/detectionClass/date/screenshot are nil → empty cells.
		let cells = lines[1].components(separatedBy: ",")
		XCTAssertEqual(cells[1], "", "title cell empty")
		XCTAssertEqual(cells.last, "", "screenshot cell empty")
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
