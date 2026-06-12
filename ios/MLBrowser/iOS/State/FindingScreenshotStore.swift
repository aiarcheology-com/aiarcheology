//
//  FindingScreenshotStore.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import UIKit
import CoreData

/// Stores finding screenshots as PNG files under Documents/Findings.
///
/// Core Data rows reference the file by FILENAME only ("<entityId>.png") — the
/// Documents container path changes across restore/device migration, so absolute
/// URLs stored in the database would dangle. The full path is always resolved
/// against the current Documents directory at read time.
enum FindingScreenshotStore {
    private static var directory: URL? {
        FileManager.default.documentDirectory?.appendingPathComponent("Findings")
    }

    static func url(forFilename filename: String) -> URL? {
        directory?.appendingPathComponent(filename)
    }

    /// Writes the screenshot for a finding, atomically (no partial file is ever
    /// visible to the sweep). Returns the canonical filename to store on the entity.
    static func save(_ image: UIImage, for entityId: UUID) throws -> String {
        guard let directory else {
            throw ModelFileStorageError.cannotAccessDocuments
        }
        guard let data = image.pngData() else {
            throw ModelFileStorageError.fileOperationFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = Finding.screenshotFilename(for: entityId)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        LoggingPolicy.debug("Finding screenshot saved (\(data.count) bytes)", logger: .storage)
        return filename
    }

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
