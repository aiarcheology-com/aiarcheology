//
//  DeepConfiguration+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 05.12.23.
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
    @NSManaged public var creationDate_: Date?
    @NSManaged public var demo: Bool
    @NSManaged public var enabled: Bool
    @NSManaged public var entityId: UUID?
    @NSManaged public var file_: URL?
    @NSManaged public var modelType: String?
    @NSManaged public var phaseOutTime: Double
    @NSManaged public var selectedSymbol_: String?
    @NSManaged public var modelDescription: String?
    @NSManaged public var modelVersion: String?

}

extension DeepConfiguration : Identifiable {

}
