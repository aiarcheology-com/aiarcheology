//
//  WebVisit+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import Foundation
import CoreData

/// One observed URL while browsing — including same-document History-API changes a map
/// application makes as the user pans/zooms. The trail lets the user replay how they
/// moved around a page. Recorded by `VisitTrailRecorder`.
@objc(WebVisit)
final public class WebVisit: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
    }
}
