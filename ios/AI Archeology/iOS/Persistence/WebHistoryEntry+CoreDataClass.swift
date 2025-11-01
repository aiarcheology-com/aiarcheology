//
//  WebHistoryEntry+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 02.12.23.
//
//

import Foundation
import CoreData

@objc(WebHistoryEntry)
final public class WebHistoryEntry: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
    }
}
