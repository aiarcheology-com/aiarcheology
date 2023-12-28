//
//  DownloadItem+CoreDataProperties.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.12.23.
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
    @NSManaged public var file_: URL?
    @NSManaged public var progress: Double
    @NSManaged public var readyToValidate: Bool
    @NSManaged public var state_: String?
    @NSManaged public var stateChanged_: Date?
    @NSManaged public var totalBytesExpectedToWrite: Int64
    @NSManaged public var totalBytesWritten: Int64
    @NSManaged public var url: URL?

}

extension DownloadItem : Identifiable {

}
