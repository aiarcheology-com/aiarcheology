//
//  DownloadItem+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//
//

import Foundation
import CoreData


extension DownloadItem {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DownloadItem> {
        return NSFetchRequest<DownloadItem>(entityName: "DownloadItem")
    }

    @NSManaged public var stateChanged: Date?
    @NSManaged public var entityId: UUID?
    @NSManaged public var url: URL?
    @NSManaged public var state: String?

}

extension DownloadItem : Identifiable {

}
