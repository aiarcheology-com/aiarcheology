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
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        // Auto-transition to draft if URL exists but still in empty state
        if let url, url.absoluteString.isEmpty.not, lifeCycle == .empty {
            transition(to: .draft)
        }
    }
}
