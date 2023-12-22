//
//  DownloadItem+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 22.12.23.
//
//

import Foundation
import CoreData


extension DownloadItem {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<DownloadItem> {
        return NSFetchRequest<DownloadItem>(entityName: "DownloadItem")
    }

    @NSManaged public var entityId: UUID?
    @NSManaged public var error: String?
    @NSManaged public var file: URL?
    @NSManaged public var progress: Double
    @NSManaged public var size: Int64
    @NSManaged public var sizeDownloaded: Int64
    @NSManaged public var state_: String?
    @NSManaged public var stateChanged_: Date?
    @NSManaged public var url: URL?
    @NSManaged public var readyTosave: Bool

}

extension DownloadItem : Identifiable {

}
