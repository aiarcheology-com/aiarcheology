//
//  WebVisit+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import Foundation
import CoreData

extension WebVisit {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<WebVisit> {
        return NSFetchRequest<WebVisit>(entityName: "WebVisit")
    }

    @NSManaged public var creationDate_: Date?
    @NSManaged public var entityId: UUID
    /// Denormalized from `page` so the location-sheet detail can filter per site cheaply.
    @NSManaged public var host: String?
    @NSManaged public var page: URL?
    @NSManaged public var lifeCycleString: String
}

extension WebVisit: Identifiable {

}
