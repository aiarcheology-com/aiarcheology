//
//  WebHistoryEntry+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 02.12.23.
//
//

import Foundation
import CoreData


extension WebHistoryEntry {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<WebHistoryEntry> {
        return NSFetchRequest<WebHistoryEntry>(entityName: "WebHistoryEntry")
    }

    @NSManaged public var entityId: UUID?
    @NSManaged public var creationDate_: Date?
    @NSManaged public var page: URL?
    @NSManaged public var bookmarked: Bool
    @NSManaged public var tags: NSSet?

}

// MARK: Generated accessors for tags
extension WebHistoryEntry {

    @objc(addTagsObject:)
    @NSManaged public func addToTags(_ value: Tag)

    @objc(removeTagsObject:)
    @NSManaged public func removeFromTags(_ value: Tag)

    @objc(addTags:)
    @NSManaged public func addToTags(_ values: NSSet)

    @objc(removeTags:)
    @NSManaged public func removeFromTags(_ values: NSSet)

}

extension WebHistoryEntry : Identifiable {

}
