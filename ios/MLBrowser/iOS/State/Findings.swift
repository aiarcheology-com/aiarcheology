//
//  Findings.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import Foundation
import CoreData

extension Finding: CoreDataManageable {
}

extension Finding: CoreDataManagableWithState {
    func validationReport() -> CoreDataManagableValidationReport {
        guard lifeCycle == .draft || lifeCycle == .ready else { return .init(issues: nil) }

        var issues: [CoreDataManagableValidationIssue] = []

        if let pageURL = page, Finding.isValidPageURL(pageURL).not {
            issues.append(.init(key: "page", message: "Invalid page url."))
        }

        if creationDate_.isNil {
            issues.append(.init(key: "creationDate", message: "Creation date is nil."))
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(key: "title", message: "Title is required."))
        }

        if isUnitRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight).not {
            issues.append(.init(key: "boundingBox", message: "Bounding box is outside the unit rect."))
        }

        if (detectionConfidence >= 0 && detectionConfidence <= 1).not {
            issues.append(.init(key: "detectionConfidence", message: "Confidence is outside 0...1."))
        }

        // Required: a finding without its screenshot reference is unusable.
        if Finding.isCanonicalScreenshotFilename(screenshotFilename, for: entityId).not {
            issues.append(.init(key: "screenshotFilename", message: "Filename is missing or does not match the entity id."))
        }

        return .init(issues: issues)
    }

    /// Extensions a stored finding screenshot may legitimately carry.
    ///
    /// `jpg` is what every new finding is written as (AIA-713); `png` is what 1.0.7 and earlier
    /// wrote. Both must stay valid FOR EVER: those files are never rewritten, so a row that
    /// accepted only the current extension would fail `validateForUpdate` the next time anything
    /// touched a pre-1.0.8 finding — turning a silent format change into user-visible data loss.
    static let supportedScreenshotExtensions: Set<String> = ["jpg", "png"]

    /// The canonical screenshot filename for a NEW finding — derived from the entity id so a
    /// stored row and its file can always be matched without extra bookkeeping.
    static func screenshotFilename(for entityId: UUID) -> String {
        "\(entityId.uuidString).jpg"
    }

    /// The screenshot filename for `entityId` carrying a specific extension, used when restoring an
    /// archived finding whose image must keep the bytes — and therefore the codec — it was exported
    /// with. Returns nil for an unsupported extension rather than inventing one.
    static func screenshotFilename(for entityId: UUID, pathExtension: String) -> String? {
        let ext = pathExtension.lowercased()
        guard supportedScreenshotExtensions.contains(ext) else { return nil }
        return "\(entityId.uuidString).\(ext)"
    }

    /// Whether `filename` is a legitimate screenshot name for `entityId`: the entity's UUID plus
    /// any supported image extension. Checked instead of equality against the current canonical
    /// name so legacy `.png` rows keep validating (see `supportedScreenshotExtensions`).
    static func isCanonicalScreenshotFilename(_ filename: String?, for entityId: UUID) -> Bool {
        guard let filename else { return false }
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        return name == entityId.uuidString && supportedScreenshotExtensions.contains(ext)
    }

    /// Pure validation: avoid main-actor-only APIs here. Findings are always captured
    /// on a remote page, so unlike WebHistoryEntry no file scheme is allowed.
    private static func isValidPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return (url.host?.isEmpty == false)
        default:
            return false
        }
    }

    private func isUnitRect(x: Double, y: Double, width: Double, height: Double) -> Bool {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite) else { return false }
        return x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }
}

// Add the validations using the core data's api:
extension Finding {
    public override func validateForInsert() throws {
        try super.validateForInsert()
        if lifeCycle == .ready {
            try throwIfInvalid()
        }
    }

    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        if lifeCycle == .ready {
            try throwIfInvalid()
        }
    }
}

extension Finding {
    /// Distinct user labels across all stored findings, for the save sheet's
    /// suggestion chips and the inventory's filter chips. Empty/whitespace-only
    /// labels are excluded.
    static func distinctLabels(in context: NSManagedObjectContext) -> [String] {
        // nonisolated(unsafe) is safe here because performAndWait executes synchronously,
        // blocking until the closure completes (same pattern as CoreDataManageable).
        nonisolated(unsafe) var result: [String] = []
        context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: "Finding")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["label_"]
            // Store-level distinct only works on SQLite; dedupe in code so the
            // in-memory test store behaves identically (and trim-collisions merge).
            do {
                let rows = try context.fetch(request)
                // Case-insensitive identity (first-seen casing wins), matching the
                // case-insensitive list filter — otherwise "Fortification" and
                // "fortification" would produce two chips.
                var seen = Set<String>()
                result = rows
                    .compactMap { $0["label_"] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty.not && seen.insert($0.lowercased()).inserted }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            } catch {
                LoggingPolicy.error("Failed to fetch distinct finding labels", error: error, logger: .storage)
            }
        }
        return result
    }
}
