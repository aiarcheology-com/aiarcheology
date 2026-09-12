//
//  FindingScreenshotStore.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import UIKit
import CoreData

/// Stores finding screenshots as JPEG files under Documents/Findings.
///
/// Core Data rows reference the file by FILENAME only ("<entityId>.jpg") — the
/// Documents container path changes across restore/device migration, so absolute
/// URLs stored in the database would dangle. The full path is always resolved
/// against the current Documents directory at read time.
///
/// **JPEG since AIA-713.** Cloud sync gives every finding a byte budget, and the PNGs this wrote
/// until 1.0.7 ran 2–6 MB each. Existing PNG files are NEVER rewritten: they stay on disk under
/// their original `.png` name, stay valid (`Finding.isCanonicalScreenshotFilename`), and load
/// unchanged — `load` judges by content, not by extension.
enum FindingScreenshotStore {
    /// Longest edge, in PIXELS, of a stored screenshot. A capture from a 3x device is ~3000 px
    /// wide; past this the extra pixels cost bytes that the sync quota has to pay for and that
    /// nothing on screen can show.
    private static let maximumLongEdgePixels: CGFloat = 2048

    /// JPEG quality for stored screenshots. Deliberately the same value the upload path will use,
    /// so syncing a finding re-encodes nothing and the bytes on the device are the bytes in the
    /// cloud. The visible cost is blocking artifacts in tight `cropThumbnail` crops of a detection.
    private static let compressionQuality: CGFloat = 0.7

    private static var directory: URL? {
        FileManager.default.documentDirectory?.appendingPathComponent("Findings")
    }

    static func url(forFilename filename: String) -> URL? {
        directory?.appendingPathComponent(filename)
    }

    /// Writes the screenshot for a finding, atomically (no partial file is ever
    /// visible to the sweep). Returns the canonical filename to store on the entity.
    static func save(_ image: UIImage, for entityId: UUID) throws -> String {
        guard let data = downscaled(image).jpegData(compressionQuality: compressionQuality) else {
            throw ModelFileStorageError.fileOperationFailed
        }
        return try save(data, for: entityId)
    }

    /// Writes already-encoded image bytes verbatim.
    ///
    /// Used by archive import (AIA-713), where re-encoding through `UIImage` would degrade the
    /// picture on every export/import cycle and break the byte-identical round-trip the importer
    /// promises. The caller is responsible for having validated the bytes as a bounded image
    /// before calling — this writes what it is given.
    ///
    /// **Named `save` on purpose.** `ArchitectureTests.testOnlyFindingRepositoryWritesScreenshots`
    /// matches a `.save` call on this type by source text, so an overload keeps this writer inside
    /// the privacy invariant; a differently-named entry point would silently escape it.
    ///
    /// (That scan reads whole files and does not exclude comments, so this note deliberately avoids
    /// spelling the matched pattern out — doing so makes this very file an offender.)
    /// - Parameter pathExtension: the codec the bytes actually are. Defaults to the canonical `jpg`
    ///   for anything this app encodes; an import passes the archived file's own extension so a
    ///   restored PNG is not stored under a name claiming to be a JPEG.
    static func save(_ data: Data, for entityId: UUID, pathExtension: String = "jpg") throws -> String {
        guard let directory else {
            throw ModelFileStorageError.cannotAccessDocuments
        }
        guard let filename = Finding.screenshotFilename(for: entityId, pathExtension: pathExtension) else {
            throw ModelFileStorageError.fileOperationFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        LoggingPolicy.debug("Finding screenshot saved (\(data.count) bytes)", logger: .storage)
        return filename
    }

    /// Stores a screenshot that is already a file, without reading it into memory (AIA-0755).
    ///
    /// An archive import stages every validated image on disk precisely so the whole set is never
    /// resident; loading each one back just to hand it to `save(_ data:)` would put the peak
    /// straight back. On APFS the copy is a clone, so this costs no additional bytes either.
    ///
    /// **Replaces by rename, exactly as `save(_ data:)`'s `.atomic` write does, and that is
    /// load-bearing.** `FindingRepository` backs up the image it is about to replace with a hard
    /// link; a writer that truncated the existing file in place would change the bytes behind that
    /// link and leave the rollback with nothing to restore.
    static func save(copyingFrom source: URL, for entityId: UUID, pathExtension: String = "jpg") throws -> String {
        guard let directory else {
            throw ModelFileStorageError.cannotAccessDocuments
        }
        guard let filename = Finding.screenshotFilename(for: entityId, pathExtension: pathExtension) else {
            throw ModelFileStorageError.fileOperationFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)

        // Copied to a sibling first, then swapped in: `copyItem` refuses an existing destination,
        // and a remove-then-copy would leave a window where the finding has no image at all.
        let staged = directory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
        do {
            // The copy sits inside the cleanup scope too: a copy that fails partway leaves a
            // partial sibling, and nothing but the orphan sweep would ever remove it.
            try FileManager.default.copyItem(at: source, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        LoggingPolicy.debug("Finding screenshot stored from a staged file", logger: .storage)
        return filename
    }

    /// Scales the image down so its longest PIXEL edge is at most `maximumLongEdgePixels`.
    /// Never upscales — a small capture is returned untouched, so the only images that pay the
    /// redraw are the ones that would otherwise waste bytes.
    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > maximumLongEdgePixels, longEdge > 0 else { return image }

        let ratio = maximumLongEdgePixels / longEdge
        let target = CGSize(
            width: max(1, (pixelSize.width * ratio).rounded()),
            height: max(1, (pixelSize.height * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // target is already in pixels
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Extension-agnostic by design: `UIImage(contentsOfFile:)` judges the bytes, so a legacy
    /// `.png` and a current `.jpg` both load through the same call.
    static func load(filename: String?) -> UIImage? {
        guard let filename, let url = url(forFilename: filename) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Best-effort delete; a leftover file is self-healed by the next `sweepOrphans`.
    static func delete(filename: String?) {
        guard let filename, let url = url(forFilename: filename) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — nothing to heal.
        } catch {
            LoggingPolicy.warning("Failed to delete finding screenshot (sweep will retry): \(error.localizedDescription)", logger: .storage)
        }
    }

    /// Deletes screenshot files that no stored finding references (e.g. a save whose
    /// entity insert failed mid-flight, or a delete whose file removal failed).
    ///
    /// The opposite direction — a row whose file is missing — intentionally renders a
    /// placeholder instead: user data is never auto-deleted. Runs on the viewContext /
    /// MainActor only when the findings list opens; the save sheet is dismissed by
    /// then, so a sweep can never interleave with a save.
    static func sweepOrphans(in context: NSManagedObjectContext) {
        guard let directory else { return }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return // No findings stored yet.
        } catch {
            LoggingPolicy.warning("Finding screenshot sweep could not list directory: \(error.localizedDescription)", logger: .storage)
            return
        }

        let referenced = Set(Finding.selectAll(in: context).compactMap(\.screenshotFilename))
        for file in files where referenced.contains(file.lastPathComponent).not {
            do {
                try FileManager.default.removeItem(at: file)
                LoggingPolicy.info("Removed orphaned finding screenshot", logger: .storage)
            } catch {
                LoggingPolicy.warning("Failed to remove orphaned finding screenshot: \(error.localizedDescription)", logger: .storage)
            }
        }
    }
}
