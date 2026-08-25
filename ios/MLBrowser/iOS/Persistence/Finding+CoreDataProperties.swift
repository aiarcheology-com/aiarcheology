//
//  Finding+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//
//

import Foundation
import CoreData

extension Finding {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Finding> {
        return NSFetchRequest<Finding>(entityName: "Finding")
    }

    /// The finder's self-declared credit, shown on the share card (AIA-0651). Optional and
    /// free text: signing in is not required, so an anonymous user types their own or leaves
    /// it blank. Prefilled from the Clerk account's name at capture only and never rewritten
    /// afterwards, so a later profile edit or sign-out cannot change the credit on a finding
    /// that has already been shared. Never the account's email address — that would put an
    /// address on a shared graphic.
    ///
    /// Unrelated to `DeepConfiguration.author`, which credits the author of an imported ML model.
    @NSManaged public var author: String?
    /// Vision-normalized bounding box in FULL-IMAGE coordinates (bottom-left origin),
    /// exactly as `DetectedObject.boundingBox` delivers it. The highlight is always
    /// drawn live from these values — never baked into the stored screenshot.
    @NSManaged public var boxHeight: Double
    @NSManaged public var boxWidth: Double
    @NSManaged public var boxX: Double
    @NSManaged public var boxY: Double
    @NSManaged public var creationDate_: Date?
    /// The tapped detection's top-confidence label identifier (model class vocabulary).
    @NSManaged public var detectionClass: String?
    /// Confidence of `detectionClass` (the primary label's confidence, 0...1).
    @NSManaged public var detectionConfidence: Double
    @NSManaged public var entityId: UUID
    /// Manually entered GPS coordinates (free text in v1).
    @NSManaged public var gps_: String?
    @NSManaged public var label_: String?
    @NSManaged public var lifeCycleString: String
    /// `DeepDriverParams.entityId` of the configuration that produced the detection.
    @NSManaged public var modelId: UUID?
    /// When this finding was last changed — the ordering key for last-write-wins cloud sync
    /// (AIA-713). Stamped automatically by `Finding.willSave()` on every mutation, so no writer
    /// can forget it; a writer that carries an AUTHORITATIVE timestamp (archive import, sync
    /// download) sets `preservesModifiedAt` to keep the value it was given.
    ///
    /// Optional because rows written before model 0.0.2 have none. Consumers must fall back to
    /// `creationDate_`, and then to server receipt time, rather than treating nil as "epoch" —
    /// a nil sorted as epoch would lose every legacy finding to any cloud copy.
    @NSManaged public var modifiedAt: Date?
    @NSManaged public var note_: String?
    /// The remote web URL the finding was captured on — never a file URL (the
    /// screenshot is referenced by `screenshotFilename` because container paths
    /// are not stable across restore).
    @NSManaged public var page: URL?
    /// Filename under Documents/Findings — always "<entityId>.png"; the full path
    /// is resolved against the current Documents directory at read time.
    @NSManaged public var screenshotFilename: String?
    /// The finding's required, user-facing name shown in the inventory list. Stored
    /// non-optional (empty-string default at the Core Data level); a `ready` finding
    /// is validated to be non-empty. Distinct from `label_`, which stays an optional
    /// filter tag.
    @NSManaged public var title: String
}

extension Finding: Identifiable {

}
