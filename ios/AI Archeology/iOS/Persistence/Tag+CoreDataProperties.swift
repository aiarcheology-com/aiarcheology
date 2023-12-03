//
//  Tag+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 02.12.23.
//
//

import Foundation
import CoreData


extension Tag {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Tag> {
        return NSFetchRequest<Tag>(entityName: "Tag")
    }

    @NSManaged public var identifier: String?
    @NSManaged public var webHistoryEntry: WebHistoryEntry?

}

extension Tag : Identifiable {

}
