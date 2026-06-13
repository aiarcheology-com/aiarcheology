//
//  FindingExporter.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import Foundation
import CoreData

/// A Core Data `Finding` flattened into a Sendable value, captured on the
/// MainActor at export time so the export work can run off the viewContext's
/// thread without touching the managed object. `id` is the single identity for
/// the zip entry name, the JSON relative path, and the source PNG lookup — they
/// can never three-way disagree.
struct FindingSnapshot: Sendable, Equatable {
	struct Box: Sendable, Equatable, Codable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	let id: UUID
	let label: String?
	let note: String?
	let gps: String?
	let page: URL?
	let detectionClass: String?
	let confidence: Double
	let date: Date?
	let box: Box
	/// The PNG on disk at capture time, or nil when the file is already missing.
	/// Copy time tolerates a disappearance too — this is only the best guess.
	let screenshotSourceURL: URL?

	init(
		id: UUID,
		label: String? = nil,
		note: String? = nil,
		gps: String? = nil,
		page: URL? = nil,
		detectionClass: String? = nil,
		confidence: Double = 0,
		date: Date? = nil,
		box: Box = Box(x: 0, y: 0, width: 0, height: 0),
		screenshotSourceURL: URL? = nil
	) {
		self.id = id
		self.label = label
		self.note = note
		self.gps = gps
		self.page = page
		self.detectionClass = detectionClass
		self.confidence = confidence
		self.date = date
		self.box = box
		self.screenshotSourceURL = screenshotSourceURL
	}

	/// Reads the managed object's attributes. Must be called on the context's
	/// queue (the viewContext is MainActor-bound), hence the isolation.
	@MainActor init(_ finding: Finding) {
		id = finding.entityId
		label = finding.label_
		note = finding.note_
		gps = finding.gps_
		page = finding.page
		detectionClass = finding.detectionClass
		confidence = finding.detectionConfidence
		date = finding.creationDate_
		box = Box(x: finding.boxX, y: finding.boxY, width: finding.boxWidth, height: finding.boxHeight)
		if
			let filename = finding.screenshotFilename,
			let url = FindingScreenshotStore.url(forFilename: filename),
			FileManager.default.fileExists(atPath: url.path) {
			screenshotSourceURL = url
		} else {
			screenshotSourceURL = nil
		}
	}
}

/// Builds a self-contained ZIP of the supplied findings — `findings.json`,
/// `findings.csv`, and `images/<id>.png` — staged in a temporary directory and
/// zipped via `NSFileCoordinator`. Stateless and off-MainActor: the heavy file
/// IO never blocks the UI. Mirrors `FindingScreenshotStore`'s enum-of-statics shape.
enum FindingExporter {
	/// Sub-directory under the temporary directory where finished zips live until
	/// the next export purges them. Kept out of the per-export staging tree so the
	/// returned URL survives the staging cleanup.
	static let exportsDirectoryName = "FindingExports"

	/// Builds the export zip and returns its URL. Off-MainActor by design — call
	/// from a detached/background task with a MainActor-built `[FindingSnapshot]`.
	static func makeZip(from snapshots: [FindingSnapshot], date: Date = .now) throws -> URL {
		let fileManager = FileManager.default
		let tempRoot = fileManager.temporaryDirectory

		// Purge any prior exports so the temp directory cannot grow unbounded.
		let exportsDirectory = tempRoot.appendingPathComponent(exportsDirectoryName, isDirectory: true)
		try? fileManager.removeItem(at: exportsDirectory)
		try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

		// Per-export staging tree: <tmp>/<UUID>/Findings/{findings.json, findings.csv, images/<id>.png}.
		let stagingRoot = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let findingsDirectory = stagingRoot.appendingPathComponent("Findings", isDirectory: true)
		let imagesDirectory = findingsDirectory.appendingPathComponent("images", isDirectory: true)
		try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: stagingRoot) }

		// Copy images FIRST: the JSON/CSV only reference the ones that actually
		// landed, so a mid-export missing/unreadable file degrades to a null path
		// rather than a dangling reference.
		var copiedIds = Set<UUID>()
		for snapshot in snapshots {
			guard let source = snapshot.screenshotSourceURL else { continue }
			let destination = imagesDirectory.appendingPathComponent("\(snapshot.id.uuidString).png")
			do {
				try fileManager.copyItem(at: source, to: destination)
				copiedIds.insert(snapshot.id)
			} catch {
				LoggingPolicy.warning("Skipped a finding image during export: \(error.localizedDescription)", logger: .storage)
			}
		}

		let jsonData = try encodeJSON(snapshots, copiedIds: copiedIds)
		try jsonData.write(to: findingsDirectory.appendingPathComponent("findings.json"), options: .atomic)

		let csv = encodeCSV(snapshots, copiedIds: copiedIds)
		try Data(csv.utf8).write(to: findingsDirectory.appendingPathComponent("findings.csv"), options: .atomic)

		let destinationZip = exportsDirectory.appendingPathComponent("Findings-\(Self.timestamp(date)).zip")
		try zip(directory: findingsDirectory, to: destinationZip, fileManager: fileManager)
		return destinationZip
	}

	// MARK: - JSON

	/// One exported row. `screenshot` carries the relative zip path, or null when
	/// the image was missing. Optionals are written as explicit JSON `null` (not
	/// omitted) so consumers see a stable schema across every row.
	private struct Row: Encodable {
		let id: String
		let label: String?
		let note: String?
		let gps: String?
		let page: String?
		let detectionClass: String?
		let confidence: Double
		let date: String?
		let box: FindingSnapshot.Box
		let screenshot: String?

		enum CodingKeys: String, CodingKey {
			case id, label, note, gps, page, detectionClass, confidence, date, box, screenshot
		}

		// Explicit `encode` (not the synthesized `encodeIfPresent`) so nil fields
		// serialize as `null` instead of vanishing from the object.
		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(id, forKey: .id)
			try container.encode(label, forKey: .label)
			try container.encode(note, forKey: .note)
			try container.encode(gps, forKey: .gps)
			try container.encode(page, forKey: .page)
			try container.encode(detectionClass, forKey: .detectionClass)
			try container.encode(confidence, forKey: .confidence)
			try container.encode(date, forKey: .date)
			try container.encode(box, forKey: .box)
			try container.encode(screenshot, forKey: .screenshot)
		}
	}

	static func encodeJSON(_ snapshots: [FindingSnapshot], copiedIds: Set<UUID>) throws -> Data {
		let formatter = ISO8601DateFormatter()
		let rows = snapshots.map { snapshot in
			Row(
				id: snapshot.id.uuidString,
				label: snapshot.label,
				note: snapshot.note,
				gps: snapshot.gps,
				page: snapshot.page?.absoluteString,
				detectionClass: snapshot.detectionClass,
				confidence: snapshot.confidence,
				date: snapshot.date.map(formatter.string(from:)),
				box: snapshot.box,
				screenshot: relativeImagePath(for: snapshot, copiedIds: copiedIds)
			)
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try encoder.encode(rows)
	}

	// MARK: - CSV

	private static let csvColumns = [
		"id", "label", "note", "gps", "page", "detectionClass",
		"confidence", "date", "boxX", "boxY", "boxWidth", "boxHeight", "screenshot"
	]

	static func encodeCSV(_ snapshots: [FindingSnapshot], copiedIds: Set<UUID>) -> String {
		let formatter = ISO8601DateFormatter()
		var lines = [csvColumns.joined(separator: ",")]
		for snapshot in snapshots {
			let fields: [String?] = [
				snapshot.id.uuidString,
				snapshot.label,
				snapshot.note,
				snapshot.gps,
				snapshot.page?.absoluteString,
				snapshot.detectionClass,
				String(snapshot.confidence),
				snapshot.date.map(formatter.string(from:)),
				String(snapshot.box.x),
				String(snapshot.box.y),
				String(snapshot.box.width),
				String(snapshot.box.height),
				relativeImagePath(for: snapshot, copiedIds: copiedIds)
			]
			// RFC-4180 line terminator is CRLF.
			lines.append(fields.map { csvField($0) }.joined(separator: ","))
		}
		return lines.joined(separator: "\r\n")
	}

	/// RFC-4180 field escaping: nil → empty field; a field containing a comma,
	/// double-quote, CR or LF is wrapped in double-quotes with internal quotes doubled.
	static func csvField(_ value: String?) -> String {
		guard let value else { return "" }
		guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
			return value
		}
		return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
	}

	// MARK: - Helpers

	private static func relativeImagePath(for snapshot: FindingSnapshot, copiedIds: Set<UUID>) -> String? {
		copiedIds.contains(snapshot.id) ? "images/\(snapshot.id.uuidString).png" : nil
	}

	/// Filename-safe timestamp (no colons) for the zip name.
	private static func timestamp(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return formatter.string(from: date)
	}

	/// Zips a directory via `NSFileCoordinator` `.forUploading`, which hands back a
	/// temporary zip valid ONLY for the duration of the accessor — so the copy to
	/// the durable destination happens inside the closure.
	private static func zip(directory: URL, to destination: URL, fileManager: FileManager) throws {
		var coordinatorError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinatorError) { zippedURL in
			do {
				if fileManager.fileExists(atPath: destination.path) {
					try fileManager.removeItem(at: destination)
				}
				try fileManager.copyItem(at: zippedURL, to: destination)
			} catch {
				copyError = error
			}
		}
		if let coordinatorError { throw coordinatorError }
		if let copyError { throw copyError }
	}
}
