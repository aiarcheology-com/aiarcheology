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
	/// The archive's images do not fit on the device. Since AIA-0755 this is a DISK bound, not a
	/// memory one: images are staged to files as they are validated, so what an import needs is
	/// room for them, not room for all of them at once in RAM.
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
	/// Where the detection sat on the captured view (AIA-0761).
	///
	/// Nil means **not stated** — an archive written before the field existed, or by a client that
	/// does not know it — and the caller keeps whatever the local row already has. It never means
	/// "the sender says there is none": zeroing on nil would let one un-updated peer strip the
	/// capture box off every device through automatic replace-import, permanently and silently.
	let captureBox: FindingSnapshot.Box?
	/// Nil for a v0 archive, which predates the attribute. The caller falls back to `creationDate`.
	let modifiedAt: Date?
	let modelId: UUID?
	/// Nil for a v0 archive, which did not record it; the caller restores such a row as `.ready`.
	let lifeCycle: String?
	/// The image's extension, taken from the validated `screenshot` path. Nil when the row has none.
	let screenshotExtension: String?
	/// Provenance as the archive stated it, or nil when it did not (AIA-0835).
	///
	/// Nil means **not stated**, never "local" — the caller keeps whatever the local row already
	/// has. An archive written before provenance existed, or by a client that does not know the
	/// field, must not be able to relabel a received finding as the user's own work.
	let source: String?
	/// When the exporting device took delivery. Nil means not stated, same rule as `source`.
	let receivedAt: Date?
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
			box: box, captureBox: captureBox, modifiedAt: modifiedAt, modelId: modelId,
			lifeCycle: lifeCycle, screenshotExtension: screenshotExtension, source: source,
			receivedAt: receivedAt
		)
	}
}

/// One finding's picture, wherever it happens to be.
///
/// The two cases are not an optimisation. An archive import validates images one at a time and
/// leaves each on disk, because holding them all was the reason a self-export could not be
/// re-imported (AIA-0755); cloud sync downloads exactly one image and already has it in memory.
/// Making the caller ask for the bytes is what keeps a 700 MB restore from ever assembling itself.
enum ImportedImage: Equatable {
	/// Bytes already in memory — the single downloaded image cloud sync applies.
	case data(Data)
	/// A validated image staged under the contents' `stagingDirectory`. Verbatim archive bytes:
	/// nothing decodes and re-encodes them, so a round trip does not degrade the picture.
	case file(URL)

	/// The bytes, read now. One image at a time is bounded by `maximumImageByteCount`; the whole
	/// archive is not, which is the entire point of staging.
	func read() throws -> Data {
		switch self {
		case let .data(data): return data
		case let .file(url): return try Data(contentsOf: url)
		}
	}
}

/// What an archive turned out to contain: rows, and the images belonging to them.
struct FindingArchiveContents: Equatable {
	let rows: [ImportedFindingRow]
	let images: [UUID: ImportedImage]
	/// Where `.file` images were staged, or nil when nothing was staged (cloud sync's single-row
	/// construction). The owner calls ``discard()`` once the contents have been applied or dropped.
	let stagingDirectory: URL?

	init(rows: [ImportedFindingRow], images: [UUID: ImportedImage], stagingDirectory: URL? = nil) {
		self.rows = rows
		self.images = images
		self.stagingDirectory = stagingDirectory
	}

	/// Removes the staged images. Non-mutating and idempotent: the contents are held in SwiftUI
	/// `@State` across an alert, and both the commit and the cancel path have to be able to call it.
	func discard() {
		guard let stagingDirectory else { return }
		try? FileManager.default.removeItem(at: stagingDirectory)
	}
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
	/// Findings plus the two manifests an export always writes. Equal to `maximumFindingCount`, an
	/// archive holding the stated maximum number of findings was refused by its own entry count.
	static let maximumEntryCount = 4_096 + 8
	static let maximumFindingCount = 4_096
	static let maximumManifestByteCount = 8 * 1024 * 1024
	static let maximumImageByteCount = 16 * 1024 * 1024
	/// Pixels, not bytes. A few hundred KB of JPEG can declare a 60000x60000 canvas, which costs
	/// ~14 GB the moment anything decodes it — a bomb that no byte-count bound catches.
	static let maximumImagePixelCount = 50_000_000
	/// Free space an import leaves alone, so staging a large archive cannot be the thing that fills
	/// the device out from under everything else.
	static let reservedFreeDiskByteCount = 64 * 1024 * 1024

	private static let manifestName = "findings.json"

	/// Where validated images are staged, one directory per import.
	///
	/// One constant, because three separate exits delete it: `read` on its own failure, the owner's
	/// `discard()` when the contents have been applied or dropped, and a purge of what an earlier
	/// RUN of the app left behind.
	static var stagingRootDirectory: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("FindingImports", isDirectory: true)
	}

	/// Where `FindingRepository` keeps the hard-link backups of the images an import replaces, one
	/// directory per import. Declared here rather than there so that ONE purge covers both trees:
	/// a kill mid-import strands the backups exactly as it strands the staging, and a link to an
	/// image that was then replaced keeps the old bytes allocated for as long as it exists.
	static var backupRootDirectory: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("FindingImportBackups", isDirectory: true)
	}

	/// A prefix only this process gives its directories, so "made by an earlier run" is a fact
	/// about a NAME rather than about timing.
	///
	/// The first version of this snapshotted the roots the first time an import ran, and that
	/// was a race: cloud sync also replaces images through `FindingRepository`, from the list's
	/// `onAppear`, and a backup it had just made could be in the snapshot -- and then deleted --
	/// while the import that needed it was still running.
	private static let processToken = UUID().uuidString

	/// A fresh directory under `root` that the purge will never touch while this process lives.
	static func transientDirectory(under root: URL) -> URL {
		root.appendingPathComponent("\(processToken)-\(UUID().uuidString)", isDirectory: true)
	}

	/// Deletes what a previous run of the app left behind — staged images and replaced-image
	/// backups — so a crash costs disk only until the next import.
	///
	/// Deliberately NOT "delete everything under the roots". The import task is unstructured and
	/// outlives the view that started it, so a user who starts a long import, leaves the findings
	/// list, comes back and starts another would otherwise have the second import delete the
	/// first one's images while it was still reading them. Anything this process named is spared.
	static func purgeStagedImportsFromEarlierRuns() {
		let mine = processToken + "-"
		for root in [stagingRootDirectory, backupRootDirectory] {
			let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
			for name in names where name.hasPrefix(mine) == false {
				try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
			}
		}
	}

	static func read(archiveAt url: URL) throws -> FindingArchiveContents {
		try read(archiveAt: url, availableCapacity: availableCapacity(forStagingOn:))
	}

	/// - Parameter availableCapacity: free bytes on the volume the staging directory sits on.
	///   Injected so the refusal can be tested without filling a disk.
	static func read(
		archiveAt url: URL,
		availableCapacity: (URL) -> Int64?
	) throws -> FindingArchiveContents {
		let reader: ZipArchiveReader
		do {
			// Read from the FILE, never from a copy of it. `Data(contentsOf:)` + `[UInt8](...)`
			// cost the archive's full size in RAM, which is what forced the 320 MB cap this method
			// used to apply -- and that cap is what made the app's own export un-importable
			// (AIA-0755). The reader touches the end record and the central directory, then one
			// local header per entry it is actually asked for.
			//
			// Deflate is required, not optional: NSFileCoordinator(.forUploading) — how this app
			// exports — compresses every entry, including already-compressed images.
			reader = try ZipArchiveReader(fileAt: url, allowsDeflate: true)
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

		let staging = transientDirectory(under: stagingRootDirectory)
		var staged = false
		// Any refusal after the directory exists takes it with it. Without this, an archive that
		// fails validation on its fortieth image leaves the first thirty-nine on disk until some
		// later import happens to purge the root -- for a user who just saw an error and may never
		// import again.
		defer { if staged == false { try? FileManager.default.removeItem(at: staging) } }
		do {
			try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		} catch {
			throw FindingArchiveImportError.unreadableArchive(error.localizedDescription)
		}

		try refuseIfItWillNotFit(rows: rows, root: root, reader: reader, availableCapacity: availableCapacity(staging))
		let images = try readImages(for: rows, root: root, reader: reader, stagingDirectory: staging)
		staged = true
		return FindingArchiveContents(rows: rows, images: images, stagingDirectory: staging)
	}

	/// Free bytes on the volume the staging directory lives on.
	///
	/// `volumeAvailableCapacityForImportantUsage` rather than the raw free space: it is the number
	/// that accounts for what iOS would purge to make room, which is what an import can actually
	/// count on.
	private static func availableCapacity(forStagingOn directory: URL) -> Int64? {
		let probe = FileManager.default.fileExists(atPath: directory.path)
			? directory
			: FileManager.default.temporaryDirectory
		return try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
			.volumeAvailableCapacityForImportantUsage
	}

	/// Refuses an archive whose images will not fit before a single one is written.
	///
	/// A fail-fast for the user, not a security bound — the security bounds are the per-image and
	/// per-entry caps, which apply whatever this decides. It is worth having because the alternative
	/// is discovering the problem partway through, having already filled the volume.
	///
	/// The declared sum is exactly what staging will cost, by the reader's construction: `bytes(of:)`
	/// sizes the inflate buffer at exactly `uncompressedSize` and refuses when the inflated length
	/// disagrees, and nothing reaches the staging directory until that call has returned. Under-
	/// declaring therefore buys an attacker no disk; it buys a truncated file that fails the image
	/// header check. The bytes are counted once because the later copy into the findings store is a
	/// clone on the same volume, not a second full-size write.
	private static func refuseIfItWillNotFit(
		rows: [ImportedFindingRow],
		root: String,
		reader: ZipArchiveReader,
		availableCapacity: Int64?
	) throws {
		guard let availableCapacity else { return }
		var declaredSizes: [String: Int] = [:]
		declaredSizes.reserveCapacity(reader.entries.count)
		for entry in reader.entries { declaredSizes[entry.name] = entry.uncompressedSize }

		var total = 0
		for row in rows {
			guard let ext = row.screenshotExtension,
				let size = declaredSizes["\(root)images/\(row.id.uuidString).\(ext)"]
			else { continue }
			// Declared sizes are attacker-chosen, so the sum is added the only way that cannot wrap.
			let (sum, overflowed) = total.addingReportingOverflow(size)
			guard overflowed == false else {
				throw FindingArchiveImportError.archiveTooLarge(byteCount: Int.max)
			}
			total = sum
		}

		let room = availableCapacity - Int64(reservedFreeDiskByteCount)
		guard Int64(total) <= room else {
			throw FindingArchiveImportError.archiveTooLarge(byteCount: total)
		}
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
		let captureBox: FindingSnapshot.Box?
		let modifiedAt: String?
		let modelId: String?
		let lifeCycle: String?
		let screenshot: String?
		let source: String?
		let receivedAt: String?
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
			// Sanitized at the boundary, not validated into a rejection. `FindingRepository.apply`
			// turns any `throwIfInvalid()` failure into `ImportRejection.invalidContent`, which
			// cloud sync counts as rejected and never retries — far too high a price for a field
			// no renderer requires. An out-of-range capture box is simply not stated.
			captureBox: raw.captureBox.flatMap(sanitizedCaptureBox),
			modifiedAt: raw.modifiedAt.flatMap(parseDate),
			modelId: raw.modelId.flatMap(UUID.init(uuidString:)),
			lifeCycle: raw.lifeCycle,
			screenshotExtension: screenshotExtension,
			source: raw.source,
			receivedAt: raw.receivedAt.flatMap(parseDate)
		)
	}

	/// A capture box the local store can hold, or nil.
	///
	/// The unit-rect rule mirrors `Finding.validationReport()`'s, deliberately: the model rule is
	/// defence in depth, and this is the gate that keeps a peer's malformed value from ever
	/// reaching it. The zero rect is rejected here too — on the wire it is indistinguishable from
	/// "not recorded", and nil already says that without asserting a degenerate rectangle.
	private static func sanitizedCaptureBox(_ box: FindingSnapshot.Box) -> FindingSnapshot.Box? {
		let values = [box.x, box.y, box.width, box.height]
		guard values.allSatisfy(\.isFinite),
		      box.x >= 0, box.y >= 0, box.width > 0, box.height > 0,
		      box.x + box.width <= 1, box.y + box.height <= 1
		else { return nil }
		return box
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

	/// Validates each image and leaves it on disk.
	///
	/// **One image is resident at a time, deliberately.** This used to build a `[UUID: Data]` and
	/// needed a 256 MB aggregate cap to bound it — which a 1.0.7-upgraded store's 2–6 MB PNGs
	/// exceeded at roughly fifty findings, so the app could not re-import its own export (AIA-0755).
	/// Writing each validated image out as it is read removes the reason for the cap rather than
	/// raising it, and the peak stays at one picture no matter how many the archive holds.
	private static func readImages(
		for rows: [ImportedFindingRow],
		root: String,
		reader: ZipArchiveReader,
		stagingDirectory: URL
	) throws -> [UUID: ImportedImage] {
		var images: [UUID: ImportedImage] = [:]
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
			// The bytes are validated BEFORE they are written, exactly as when they were validated
			// before being kept: a file that is not an image never reaches the staging directory.
			try autoreleasepool {
				let data = Data(bytes)
				try validateImageDimensions(data, id: row.id)
				// The name is built from the row's validated UUID, never from the entry name, so
				// the staging directory is as traversal-proof as the findings store itself.
				let staged = stagingDirectory.appendingPathComponent("\(row.id.uuidString).\(ext)")
				do {
					try data.write(to: staged, options: .atomic)
				} catch {
					// Out of room is the expected failure here and says something true about the
					// archive; anything else is this device having a bad day and must not be
					// reported as "your archive is too large". The caller's staging cleanup is what
					// keeps either from costing the disk twice.
					let failure = error as NSError
					if failure.domain == NSCocoaErrorDomain, failure.code == NSFileWriteOutOfSpaceError {
						throw FindingArchiveImportError.archiveTooLarge(byteCount: data.count)
					}
					throw FindingArchiveImportError.unreadableArchive(error.localizedDescription)
				}
				images[row.id] = .file(staged)
			}
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
