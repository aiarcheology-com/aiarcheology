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
/// the zip entry name, the JSON relative path, and the source image lookup — they
/// can never three-way disagree.
struct FindingSnapshot: Sendable, Equatable {
	struct Box: Sendable, Equatable, Codable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	let id: UUID
	let title: String
	let label: String?
	let note: String?
	/// The finder's credit (AIA-0651), nil when it was left blank.
	let author: String?
	let gps: String?
	let page: URL?
	let detectionClass: String?
	let confidence: Double
	let date: Date?
	let box: Box
	/// Last-write-wins ordering key (AIA-713). Nil only for rows that predate model 0.0.2.
	let modifiedAt: Date?
	/// The configuration that produced the detection. Carried so a restored finding keeps its
	/// provenance instead of becoming an anonymous box.
	let modelId: UUID?
	/// `CoreDataManageableState` raw value. The escape-hatch export deliberately includes every
	/// lifecycle, so restoring one as `.ready` unconditionally would change what it means.
	let lifeCycle: String
	/// The image on disk at capture time, or nil when the file is already missing.
	/// Copy time tolerates a disappearance too — this is only the best guess.
	let screenshotSourceURL: URL?

	init(
		id: UUID,
		title: String = "",
		label: String? = nil,
		note: String? = nil,
		author: String? = nil,
		gps: String? = nil,
		page: URL? = nil,
		detectionClass: String? = nil,
		confidence: Double = 0,
		date: Date? = nil,
		box: Box = Box(x: 0, y: 0, width: 0, height: 0),
		modifiedAt: Date? = nil,
		modelId: UUID? = nil,
		lifeCycle: String = CoreDataManageableState.ready.rawValue,
		screenshotSourceURL: URL? = nil
	) {
		self.id = id
		self.title = title
		self.label = label
		self.note = note
		self.author = author
		self.gps = gps
		self.page = page
		self.detectionClass = detectionClass
		self.confidence = confidence
		self.date = date
		self.box = box
		self.modifiedAt = modifiedAt
		self.modelId = modelId
		self.lifeCycle = lifeCycle
		self.screenshotSourceURL = screenshotSourceURL
	}

	/// Reads the managed object's attributes. Must be called on the context's
	/// queue (the viewContext is MainActor-bound), hence the isolation.
	/// A snapshot whose ordering key is stated rather than read off the finding.
	///
	/// Cloud sync needs this: the wire carries whole milliseconds and the server may clamp a
	/// future-dated clock, so the metadata it stores has to say exactly what the index says. A
	/// snapshot carrying the raw local `Date` would restore a timestamp the index disagrees with.
	@MainActor init(_ finding: Finding, modifiedAt: Date) {
		self.init(finding)
		self = FindingSnapshot(
			id: id, title: title, label: label, note: note, author: author, gps: gps, page: page,
			detectionClass: detectionClass, confidence: confidence, date: date, box: box,
			modifiedAt: modifiedAt, modelId: modelId, lifeCycle: lifeCycle,
			screenshotSourceURL: screenshotSourceURL
		)
	}

	@MainActor init(_ finding: Finding) {
		id = finding.entityId
		title = finding.title
		label = finding.label_
		note = finding.note_
		author = finding.author
		gps = finding.gps_
		page = finding.page
		detectionClass = finding.detectionClass
		confidence = finding.detectionConfidence
		date = finding.creationDate_
		box = Box(x: finding.boxX, y: finding.boxY, width: finding.boxWidth, height: finding.boxHeight)
		modifiedAt = finding.modifiedAt
		modelId = finding.modelId
		lifeCycle = finding.lifeCycleString
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
/// `findings.csv`, and `images/<id>.<ext>` — staged in a temporary directory and
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

		// Per-export staging tree: <tmp>/<UUID>/Findings/{findings.json, findings.csv, images/<id>.<ext>}.
		// NOTE: the zip's root entry is `Findings/`, because NSFileCoordinator zips the DIRECTORY.
		// Every reader must resolve `screenshot` against findings.json's parent, not the zip root.
		let stagingRoot = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let findingsDirectory = stagingRoot.appendingPathComponent("Findings", isDirectory: true)
		let imagesDirectory = findingsDirectory.appendingPathComponent("images", isDirectory: true)
		try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: stagingRoot) }

		// Copy images FIRST: the JSON/CSV only reference the ones that actually
		// landed, so a mid-export missing/unreadable file degrades to a null path
		// rather than a dangling reference.
		var copiedImageNames: [UUID: String] = [:]
		for snapshot in snapshots {
			guard let source = snapshot.screenshotSourceURL else { continue }
			// The extension follows the FILE, not a constant: a store upgraded from 1.0.7 holds
			// legacy .png alongside current .jpg, and both must export under their real name.
			let name = imageEntryName(for: snapshot.id, source: source)
			let destination = imagesDirectory.appendingPathComponent(name)
			do {
				try fileManager.copyItem(at: source, to: destination)
				copiedImageNames[snapshot.id] = name
			} catch {
				LoggingPolicy.warning("Skipped a finding image during export: \(error.localizedDescription)", logger: .storage)
			}
		}

		let jsonData = try encodeJSON(snapshots, copiedImageNames: copiedImageNames)
		try jsonData.write(to: findingsDirectory.appendingPathComponent("findings.json"), options: .atomic)

		let csv = encodeCSV(snapshots, copiedImageNames: copiedImageNames)
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
		let title: String
		let label: String?
		let note: String?
		let author: String?
		let gps: String?
		let page: String?
		let detectionClass: String?
		let confidence: Double
		let date: String?
		let box: FindingSnapshot.Box
		let modifiedAt: String?
		let modelId: String?
		let lifeCycle: String
		let screenshot: String?

		enum CodingKeys: String, CodingKey {
			case id, title, label, note, author, gps, page, detectionClass, confidence, date, box
			case modifiedAt, modelId, lifeCycle, screenshot
		}

		// Explicit `encode` (not the synthesized `encodeIfPresent`) so nil fields
		// serialize as `null` instead of vanishing from the object.
		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(id, forKey: .id)
			try container.encode(title, forKey: .title)
			try container.encode(label, forKey: .label)
			try container.encode(note, forKey: .note)
			try container.encode(author, forKey: .author)
			try container.encode(gps, forKey: .gps)
			try container.encode(page, forKey: .page)
			try container.encode(detectionClass, forKey: .detectionClass)
			try container.encode(confidence, forKey: .confidence)
			try container.encode(date, forKey: .date)
			try container.encode(box, forKey: .box)
			try container.encode(modifiedAt, forKey: .modifiedAt)
			try container.encode(modelId, forKey: .modelId)
			try container.encode(lifeCycle, forKey: .lifeCycle)
			try container.encode(screenshot, forKey: .screenshot)
		}
	}

	/// The archive schema this build writes. Bumped only for a change an older reader could
	/// MISREAD; additive nullable columns do not need it. Version 0 is the bare top-level array
	/// 1.0.7 shipped — the importer still accepts it and always will.
	static let schemaVersion = 1

	/// The `{schemaVersion, findings}` envelope written to `findings.json`.
	private struct Document: Encodable {
		let schemaVersion: Int
		let findings: [Row]
	}

	static func encodeJSON(_ snapshots: [FindingSnapshot], copiedImageNames: [UUID: String]) throws -> Data {
		let formatter = ISO8601DateFormatter()
		// Fractional seconds for the last-write-wins key ONLY: two edits inside one second must
		// not tie. `date` keeps whole-second formatting so v0 readers see the field unchanged.
		let preciseFormatter = ISO8601DateFormatter()
		preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let rows = snapshots.map { snapshot in
			Row(
				id: snapshot.id.uuidString,
				title: snapshot.title,
				label: snapshot.label,
				note: snapshot.note,
				author: snapshot.author,
				gps: snapshot.gps,
				page: snapshot.page?.absoluteString,
				detectionClass: snapshot.detectionClass,
				confidence: snapshot.confidence,
				date: snapshot.date.map(formatter.string(from:)),
				box: snapshot.box,
				modifiedAt: snapshot.modifiedAt.map(preciseFormatter.string(from:)),
				modelId: snapshot.modelId?.uuidString,
				lifeCycle: snapshot.lifeCycle,
				screenshot: relativeImagePath(for: snapshot, copiedImageNames: copiedImageNames)
			)
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try encoder.encode(Document(schemaVersion: schemaVersion, findings: rows))
	}

	// MARK: - CSV

	/// Positionally coupled with the `fields` array in `encodeCSV` — nothing enforces their
	/// agreement, so a new column must be appended to BOTH, in the same place.
	private static let csvColumns = [
		"id", "title", "label", "note", "gps", "page", "detectionClass",
		"confidence", "date", "boxX", "boxY", "boxWidth", "boxHeight", "screenshot", "author",
		"modifiedAt", "modelId", "lifeCycle"
	]

	static func encodeCSV(_ snapshots: [FindingSnapshot], copiedImageNames: [UUID: String]) -> String {
		let formatter = ISO8601DateFormatter()
		let preciseFormatter = ISO8601DateFormatter()
		preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		var lines = [csvColumns.joined(separator: ",")]
		for snapshot in snapshots {
			let fields: [String?] = [
				snapshot.id.uuidString,
				snapshot.title,
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
				relativeImagePath(for: snapshot, copiedImageNames: copiedImageNames),
				snapshot.author,
				snapshot.modifiedAt.map(preciseFormatter.string(from:)),
				snapshot.modelId?.uuidString,
				snapshot.lifeCycle
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

	/// The zip entry name for a finding's image: the finding id plus the extension the file
	/// actually carries on disk, lowercased. Falls back to `jpg` for a file with no extension.
	private static func imageEntryName(for id: UUID, source: URL) -> String {
		let ext = source.pathExtension.lowercased()
		return "\(id.uuidString).\(ext.isEmpty ? "jpg" : ext)"
	}

	/// The path recorded in the JSON/CSV `screenshot` column, relative to the `Findings/`
	/// directory that is the archive's root — NOT to the zip root, which also contains that
	/// directory. Nil when the image was not copied.
	private static func relativeImagePath(for snapshot: FindingSnapshot, copiedImageNames: [UUID: String]) -> String? {
		copiedImageNames[snapshot.id].map { "images/\($0)" }
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
