//
//  Finding+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//
//

import Foundation
import CoreData

@objc(Finding)
final public class Finding: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
    }
}
