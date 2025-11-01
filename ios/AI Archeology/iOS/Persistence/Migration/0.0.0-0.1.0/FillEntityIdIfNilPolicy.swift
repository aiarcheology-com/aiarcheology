//
//  FillEntityIdIfNilPolicy.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 31.10.25.
//

import CoreData

@objc(FillEntityIdIfNilPolicy)
final class FillEntityIdIfNilPolicy: NSEntityMigrationPolicy {
    override func createDestinationInstances(forSource s: NSManagedObject,
                                             in mapping: NSEntityMapping,
                                             manager: NSMigrationManager) throws {
        guard let destName = mapping.destinationEntityName else { return }
        let instance = NSEntityDescription.insertNewObject(forEntityName: destName,
                                                    into: manager.destinationContext)
        
        // copy all attributes except 'entityId'
        let attrs = s.entity.attributesByName.keys
        for key in attrs where key != "entityId" {
            instance.setValue(s.value(forKey: key), forKey: key)
        }
        
        // fill required UUID
        if let uuid = s.value(forKey: "entityId") as? UUID {
            instance.setValue(uuid, forKey: "entityId")
        } else {
            instance.setValue(UUID(), forKey: "entityId")
        }
        
        // let Core Data wire relationships using the association
        manager.associate(sourceInstance: s, withDestinationInstance: instance, for: mapping)
    }
}
