//
//  FillEntityIdIfNilPolicy.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 31.10.25.
//

import CoreData

@objc(FillEntityIdIfNilPolicy)
final class FillEntityIdIfNilPolicy: NSEntityMigrationPolicy {
    override func createDestinationInstances(forSource source: NSManagedObject,
                                             in mapping: NSEntityMapping,
                                             manager: NSMigrationManager) throws {
        guard let destName = mapping.destinationEntityName else { return }
        let destination = NSEntityDescription.insertNewObject(forEntityName: destName,
                                                    into: manager.destinationContext)
        
        // copy all attributes except 'entityId'
        let attrs = source.entity.attributesByName.keys
        for key in attrs where (key != "entityId" || key != "modelType") {
            destination.setValue(source.value(forKey: key), forKey: key)
        }
        
        if let uuid = source.value(forKey: "entityId") as? UUID {
            destination.setValue(uuid, forKey: "entityId")
        } else {
            destination.setValue(UUID(), forKey: "entityId")
        }

        if let model = source.value(forKey: "modelType") as? String {
            destination.setValue(model, forKey: "modelTypeString")
        }
        
        // setup lifeCycle enum as string
        destination.setValue("ready", forKey: "lifeCycleString")
        
        // let Core Data wire relationships using the association
        manager.associate(sourceInstance: source, withDestinationInstance: destination, for: mapping)
    }
}
