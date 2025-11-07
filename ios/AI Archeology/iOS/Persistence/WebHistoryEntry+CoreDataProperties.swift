//
//  WebHistoryEntry+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//
//

import Foundation
import CoreData


extension WebHistoryEntry {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<WebHistoryEntry> {
        return NSFetchRequest<WebHistoryEntry>(entityName: "WebHistoryEntry")
    }

    @NSManaged public var bookmarked: Bool
    @NSManaged public var creationDate_: Date?
    @NSManaged public var entityId: UUID
    @NSManaged public var page: URL?
    @NSManaged public var lifeCycleString: String
}

extension WebHistoryEntry : Identifiable {

}
