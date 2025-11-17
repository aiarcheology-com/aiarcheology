//
//  DeepConfiguration+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 20.11.23.
//
//

import Foundation
import CoreData

@objc(DeepConfiguration)
final public class DeepConfiguration: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
    }
}
