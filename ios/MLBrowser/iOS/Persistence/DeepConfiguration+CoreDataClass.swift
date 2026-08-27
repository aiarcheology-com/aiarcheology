//
//  DeepConfiguration+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 20.11.23.
//
//

import Foundation
import CoreData
import SwiftUI

@objc(DeepConfiguration)
final public class DeepConfiguration: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
        // AIA-0757: was `random(range: 0.1...0.6)`, which capped every component at 153/255 — so a
        // component above 200 was impossible by construction and detections read as muddy over
        // hillshade imagery. Only new configurations are affected: `annotationColor` is persisted
        // and user-editable through `ConfigurationForm`, so a stored value may be a deliberate
        // choice and nothing here can tell one from an old default.
        self.annotationColor = Color.vividAnnotation()
    }
}
