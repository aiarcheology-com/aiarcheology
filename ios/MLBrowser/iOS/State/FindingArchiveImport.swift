//
//  FindingArchiveImport.swift
//  AI Archeology
//
//  Reading a findings export archive back (AIA-713, Phase 1).
//

import Foundation
import ImageIO
import NativeModelConverter

/// Why an archive could not be imported. Every case is a refusal the user can be told about; none
/// of them leaves anything written.
enum FindingArchiveImportError: Error, Equatable {
	case unreadableArchive(String)
	/// No `findings.json` anywhere in the archive — it is a zip, but not one of ours.
	case noFindingsManifest
	case tooManyEntries(Int)
	case tooManyFindings(Int)
	/// Two rows in one manifest claim the same finding id. Refused outright: they address the same
	/// row and the same image filename, so processing both means one silently overwrites the other's
	/// picture — and a failure on the second can leave the first's bytes attached to the original row.
	case duplicateFindingId(UUID)
	/// The archive declares a schema this build does not know how to read.
	case unsupportedSchemaVersion(Int)
	/// The archive's images exceed what an import may hold in memory in total, whatever each
	/// individual image was allowed to be.
	case archiveTooLarge(byteCount: Int)
	case malformedManifest(String)
	/// An image whose DECLARED size or pixel dimensions exceed what an import may hold.
	case imageTooLarge(id: UUID)
	case imageDimensionsTooLarge(id: UUID, width: Int, height: Int)
	/// Bytes in an image slot that ImageIO does not recognise as an image at all.
	case notAnImage(id: UUID)
}

/// One finding decoded from `findings.json`, already validated as far as pure data allows.
struct ImportedFindingRow: Equatable {
	let id: UUID
	let title: String
	let label: String?
	let note: String?
	let author: String?
	let gps: String?
	let page: URL?
	let detectionClass: String?
	let confidence: Double
	let creationDate: Date?
	let box: FindingSnapshot.Box
	/// Nil for a v0 archive, which predates the attribute. The caller falls back to `creationDate`.
	let modifiedAt: Date?
	let modelId: UUID?
	/// Nil for a v0 archive, which did not record it; the caller restores such a row as `.ready`.
	let lifeCycle: String?
	/// The image's extension, taken from the validated `screenshot` path. Nil when the row has none.
	let screenshotExtension: String?
}

extension ImportedFindingRow {
	/// The same row with a stated ordering key.
	///
	/// Cloud sync needs it: the index is authoritative about `modifiedAt`, so a metadata blob that
	/// disagrees -- an older client's rounding, or a value the server clamped after it was written
	/// -- must not be the thing that sets the local timestamp.
	func replacingModifiedAt(_ modifiedAt: Date) -> ImportedFindingRow {
		ImportedFindingRow(
			id: id, title: title, label: label, note: note, author: author, gps: gps, page: page,
			detectionClass: detectionClass, confidence: confidence, creationDate: creationDate,
			box: box, modifiedAt: modifiedAt, modelId: modelId, lifeCycle: lifeCycle,
			screenshotExtension: screenshotExtension
		)
	}
}

/// What an archive turned out to contain: rows, and the image bytes belonging to them.
struct FindingArchiveContents: Equatable {
	let rows: [ImportedFindingRow]
	/// Verbatim archive bytes, keyed by finding id. Stored as-is rather than decoded and re-encoded,
	/// so an export/import round trip does not degrade the picture.
	let images: [UUID: Data]
}

/// Pure, Core-Data-free decoding of a findings archive.
///
/// **Deliberately off the MainActor and free of any store access.** `FindingRepository` is
/// `@MainActor` on the `viewContext`, so unzipping, JSON parsing and image validation for a large
/// archive would otherwise all run on the main thread.
///
/// **Path traversal is structurally impossible here, not merely checked for.** Nothing in this type
/// ever uses an archive-supplied name as a filesystem destination: images are addressed by the
/// finding's validated UUID, and the file they are eventually written to is
/// `Documents/Findings/<entityId>.<ext>`, built from that UUID by `Finding.screenshotFilename`.
/// A `../../etc/passwd` entry name cannot escape anywhere, because it is never joined to a path —
/// it simply fails to match the canonical `images/<id>.<ext>` a row is allowed to reference.
enum FindingArchiveImport {
	/// Ceilings, all applied before anything is allocated or written.
	static let maximumEntryCount = 4_096
	static let maximumFindingCount = 4_096
	static let maximumManifestByteCount = 8 * 1024 * 1024
	static let maximumImageByteCount = 16 * 1024 * 1024
	/// Pixels, not bytes. A few hundred KB of JPEG can declare a 60000x60000 canvas, which costs
	/// ~14 GB the moment anything decodes it — a bomb that no byte-count bound catches.
	static let maximumImagePixelCount = 50_000_000
	/// Total inflated image bytes an import may hold at once. The per-image cap alone is not a
	/// bound: 4,096 findings at 16 MB each satisfies every other limit and still asks for ~64 GB,
	/// and a highly compressible payload makes the ZIP itself small enough to look harmless.
	static let maximumTotalImageByteCount = 256 * 1024 * 1024

	private static let manifestName = "findings.json"

	static func read(archiveAt url: URL) throws -> FindingArchiveContents {
		let data: Data
		do {
			data = try Data(contentsOf: url, options: .mappedIfSafe)
		} catch {
			throw FindingArchiveImportError.unreadableArchive(error.localizedDescription)
		}
		return try read(archiveBytes: [UInt8](data))
	}

	static func read(archiveBytes: [UInt8]) throws -> FindingArchiveContents {
		let reader: ZipArchiveReader
		do {
			// Deflate is required, not optional: NSFileCoordinator(.forUploading) — how this app
			// exports — compresses every entry, including already-compressed images.
			reader = try ZipArchiveReader(bytes: archiveBytes, allowsDeflate: true)
		} catch {
			throw FindingArchiveImportError.unreadableArchive("\(error)")
		}

		let entries = reader.entries
		guard entries.count <= maximumEntryCount else {
			throw FindingArchiveImportError.tooManyEntries(entries.count)
		}

		// The archive's root is `findings.json`'s PARENT, not the zip root: NSFileCoordinator zips
		// the Findings DIRECTORY, so every entry is `Findings/...` and the manifest's `screenshot`
		// paths are relative to that parent. Locating the manifest and deriving the root from it
		// works for both shapes without hard-coding either.
		guard let manifest = entries.first(where: { entryName($0.name, isNamed: manifestName) }) else {
			throw FindingArchiveImportError.noFindingsManifest
		}
		let root = String(manifest.name.dropLast(manifestName.count)) // "" or "Findings/"

		let manifestBytes: [UInt8]
		do {
			manifestBytes = try reader.bytes(named: manifest.name, maximumByteCount: maximumManifestByteCount)
		} catch {
			throw FindingArchiveImportError.unreadableArchive("\(error)")
		}

		let rows = try decodeRows(Data(manifestBytes))
		let images = try readImages(for: rows, root: root, reader: reader)
		return FindingArchiveContents(rows: rows, images: images)
	}

	/// True when `name` is exactly `<something>/findings.json` or `findings.json` — one manifest at
	/// one depth. A name merely ENDING in the manifest name (`evil-findings.json`) does not match.
	private static func entryName(_ name: String, isNamed target: String) -> Bool {
		name == target || (name.hasSuffix("/" + target) && name.dropLast(target.count + 1).contains("/") == false)
	}

	// MARK: - Manifest

	/// Decodes a manifest, whether it came out of an archive or off the network.
	///
	/// Not private because cloud sync stores each finding's `meta.json` in exactly this shape, with
	/// a single row. Sharing the codec is the point: one place decides what a finding's fields mean
	/// on the wire, so an archive and a synced copy cannot drift into disagreeing.
	static func decodeRows(_ data: Data) throws -> [ImportedFindingRow] {
		// Sniff the top level rather than try-decoding both shapes: a v1 envelope containing one bad
		// row must report THAT, not fall through to "this is not an array either".
		let top: Any
		do {
			top = try JSONSerialization.jsonObject(with: data)
		} catch {
			throw FindingArchiveImportError.malformedManifest(error.localizedDescription)
		}

		let decoder = JSONDecoder()
		do {
			let raw: [RawRow]
			if top is [Any] {
				// v0: the bare top-level array 1.0.7 shipped. It must import for ever.
				raw = try decoder.decode([RawRow].self, from: data)
			} else if top is [String: Any] {
				let envelope = try decoder.decode(Envelope.self, from: data)
				// A newer schema may have changed what a field MEANS, not merely added one. Reading
				// it as v1 would silently default whatever moved, so an unknown version is refused
				// rather than guessed at — which is the entire reason the envelope exists.
				guard envelope.schemaVersion <= FindingExporter.schemaVersion else {
					throw FindingArchiveImportError.unsupportedSchemaVersion(envelope.schemaVersion)
				}
				raw = envelope.findings
			} else {
				throw FindingArchiveImportError.malformedManifest("top level is neither an array nor an object")
			}
			guard raw.count <= maximumFindingCount else {
				throw FindingArchiveImportError.tooManyFindings(raw.count)
			}
			let rows = try raw.map(validated)
			// Byte-exact duplicate detection, mirroring the zip reader's rule for entry names: two
			// rows claiming one id are an attempt to make the write ambiguous, not a convenience.
			var seen = Set<UUID>(minimumCapacity: rows.count)
			for row in rows where seen.insert(row.id).inserted == false {
				throw FindingArchiveImportError.duplicateFindingId(row.id)
			}
			return rows
		} catch let error as FindingArchiveImportError {
			throw error
		} catch {
			throw FindingArchiveImportError.malformedManifest("\(error)")
		}
	}

	private struct Envelope: Decodable {
		let schemaVersion: Int
		let findings: [RawRow]
	}

	private struct RawRow: Decodable {
		let id: String
		let title: String?
		let label: String?
		let note: String?
		let author: String?
		let gps: String?
		let page: String?
		let detectionClass: String?
		let confidence: Double?
		let date: String?
		let box: FindingSnapshot.Box?
		let modifiedAt: String?
		let modelId: String?
		let lifeCycle: String?
		let screenshot: String?
	}

	private static func validated(_ raw: RawRow) throws -> ImportedFindingRow {
		guard let id = UUID(uuidString: raw.id) else {
			throw FindingArchiveImportError.malformedManifest("finding id '\(raw.id)' is not a UUID")
		}
		let box = raw.box ?? FindingSnapshot.Box(x: 0, y: 0, width: 0, height: 0)

		// The screenshot path is only ever accepted in its canonical form. This is what stops one
		// row claiming another row's image — and, with it, any name that is not exactly this shape.
		var screenshotExtension: String?
		if let screenshot = raw.screenshot {
			guard let ext = canonicalScreenshotExtension(screenshot, for: id) else {
				throw FindingArchiveImportError.malformedManifest(
					"finding \(id) references '\(screenshot)', which is not its own images/<id>.<ext>"
				)
			}
			screenshotExtension = ext
		}

		return ImportedFindingRow(
			id: id,
			title: raw.title ?? "",
			label: raw.label,
			note: raw.note,
			author: raw.author,
			gps: raw.gps,
			page: raw.page.flatMap(URL.init(string:)),
			detectionClass: raw.detectionClass,
			confidence: raw.confidence ?? 0,
			creationDate: raw.date.flatMap(parseDate),
			box: box,
			modifiedAt: raw.modifiedAt.flatMap(parseDate),
			modelId: raw.modelId.flatMap(UUID.init(uuidString:)),
			lifeCycle: raw.lifeCycle,
			screenshotExtension: screenshotExtension
		)
	}

	/// `images/<id>.<ext>` with a supported extension and nothing else — no directory components, no
	/// other id, no traversal.
	private static func canonicalScreenshotExtension(_ path: String, for id: UUID) -> String? {
		let prefix = "images/"
		guard path.hasPrefix(prefix) else { return nil }
		let file = String(path.dropFirst(prefix.count))
		guard file.contains("/") == false else { return nil }
		let name = (file as NSString).deletingPathExtension
		let ext = (file as NSString).pathExtension.lowercased()
		guard name == id.uuidString, Finding.supportedScreenshotExtensions.contains(ext) else { return nil }
		return ext
	}

	/// Accepts both the whole-second form the exporter has always written and the fractional-second
	/// form `modifiedAt` uses.
	private static func parseDate(_ text: String) -> Date? {
		let fractional = ISO8601DateFormatter()
		fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
	}

	// MARK: - Images

	private static func readImages(
		for rows: [ImportedFindingRow],
		root: String,
		reader: ZipArchiveReader
	) throws -> [UUID: Data] {
		var images: [UUID: Data] = [:]
		var totalByteCount = 0
		for row in rows {
			guard let ext = row.screenshotExtension else { continue }
			let name = "\(root)images/\(row.id.uuidString).\(ext)"
			let bytes: [UInt8]
			do {
				bytes = try reader.bytes(named: name, maximumByteCount: maximumImageByteCount)
			} catch ZipArchiveReaderError.entryNotFound {
				// A manifest that promises an image the archive does not carry restores the finding
				// without one — a row whose file is missing is already a supported state.
				continue
			} catch ZipArchiveReaderError.entryTooLarge {
				throw FindingArchiveImportError.imageTooLarge(id: row.id)
			} catch {
				throw FindingArchiveImportError.unreadableArchive("\(error)")
			}
			let data = Data(bytes)
			// Aggregate budget, checked as we go: the per-image cap bounds one picture, this bounds
			// the import.
			totalByteCount += data.count
			guard totalByteCount <= maximumTotalImageByteCount else {
				throw FindingArchiveImportError.archiveTooLarge(byteCount: totalByteCount)
			}
			try validateImageDimensions(data, id: row.id)
			images[row.id] = data
		}
		return images
	}

	/// Reads the image's declared dimensions from its header WITHOUT decoding it.
	///
	/// A byte-count bound is not enough on its own: a small JPEG can declare an enormous canvas, and
	/// the allocation only happens later, wherever the findings list first draws it. Checking here
	/// means the bytes are never stored in the first place.
	/// The same bounds, for image bytes that arrived over the network rather than out of an archive.
	///
	/// Cloud sync downloads images straight into the repository's import machinery, which skips the
	/// archive reader that would otherwise have applied these checks. A same-account device can be
	/// compromised or simply buggy, and a small file declaring an enormous canvas costs nothing to
	/// store and everything to draw.
	static func validateDownloadedImage(_ data: Data, id: UUID) throws {
		guard data.count <= maximumImageByteCount else {
			throw FindingArchiveImportError.imageTooLarge(id: id)
		}
		try validateImageDimensions(data, id: id)
	}

	private static func validateImageDimensions(_ data: Data, id: UUID) throws {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int
		else {
			throw FindingArchiveImportError.notAnImage(id: id)
		}
		guard width > 0, height > 0 else {
			throw FindingArchiveImportError.notAnImage(id: id)
		}
		guard width.multipliedReportingOverflow(by: height).overflow == false,
			width * height <= maximumImagePixelCount
		else {
			throw FindingArchiveImportError.imageDimensionsTooLarge(id: id, width: width, height: height)
		}
	}
}
