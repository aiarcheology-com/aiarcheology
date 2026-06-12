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
    @NSManaged public var note_: String?
    /// The remote web URL the finding was captured on — never a file URL (the
    /// screenshot is referenced by `screenshotFilename` because container paths
    /// are not stable across restore).
    @NSManaged public var page: URL?
    /// Filename under Documents/Findings — always "<entityId>.png"; the full path
    /// is resolved against the current Documents directory at read time.
    @NSManaged public var screenshotFilename: String?
}

extension Finding: Identifiable {

}
