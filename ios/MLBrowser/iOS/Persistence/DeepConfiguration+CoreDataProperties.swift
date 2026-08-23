//
//  DeepConfiguration+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//
//

import Foundation
import CoreData

extension DeepConfiguration {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DeepConfiguration> {
        return NSFetchRequest<DeepConfiguration>(entityName: "DeepConfiguration")
    }
    
    @NSManaged public var annotationColor_: Data?
    @NSManaged public var author: String?
    @NSManaged public var computeUnitString: String?
    @NSManaged public var creationDate_: Date?
    @NSManaged public var demo: Bool
    @NSManaged public var enabled: Bool
    @NSManaged public var entityId: UUID
    @NSManaged public var file_: URL?
    @NSManaged public var downloadURL: URL?
    @NSManaged public var license: String?
    @NSManaged public var modelDescription: String?
    @NSManaged public var modelTypeString: String?
    /// Whether the model's type came from the metadata parser (an authoritative `task`/preview/turi
    /// key) rather than being left for the user. When `true` the type is locked (read-only) in
    /// settings; when `false` the parser couldn't decide it, so the user picks it (AIA-0402).
    @NSManaged public var modelTypeParsed: Bool
    @NSManaged public var modelVersion: String?
    @NSManaged public var phaseOutTime: Double
    @NSManaged public var selectedSymbol_: String?
    @NSManaged public var lifeCycleString: String
}

extension DeepConfiguration: Identifiable {}
