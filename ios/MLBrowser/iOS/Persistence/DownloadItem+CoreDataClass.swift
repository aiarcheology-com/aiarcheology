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
        // The Models list sorts by stateChanged_ descending; without a creation stamp every row is
        // nil, the sort degenerates to insertion order, and a (+)-added row lands at the BOTTOM of
        // a long history (AIA-0459). Stamping here puts new rows on top.
        self.stateChanged_ = .now
    }
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        // Auto-transition to draft if URL exists but still in empty state
        if let url, url.absoluteString.isEmpty.not, lifeCycle == .empty {
            transition(to: .draft)
        }
    }
}
