//
//  DownloadItem+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 19.12.23.
//
//

import Foundation
import CoreData

@objc(DownloadItem)
final public class DownloadItem: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
    }
}
