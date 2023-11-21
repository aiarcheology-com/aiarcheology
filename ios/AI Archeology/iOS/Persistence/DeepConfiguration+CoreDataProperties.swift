//
//  DeepConfiguration+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 21.11.23.
//
//

import Foundation
import CoreData


extension DeepConfiguration {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DeepConfiguration> {
        return NSFetchRequest<DeepConfiguration>(entityName: "DeepConfiguration")
    }

    @NSManaged public var fileName: URL?
    @NSManaged public var modelName: String?
    @NSManaged public var modelType: String?
    @NSManaged public var authorName: String?
    @NSManaged public var creationDate_: Date?
    @NSManaged public var annotationColor_: Data?
    @NSManaged public var phaseOutTime: Double
    @NSManaged public var selectedSymbol: Int16
    @NSManaged public var enabled: Bool
    @NSManaged public var entityId: UUID?

}

extension DeepConfiguration : Identifiable {

}
