//
//  FillEntityIdIfNilPolicy.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 31.10.25.
//

import CoreData
import OSLog

// Migration from 0.0.0 to 0.0.1

fileprivate struct MigrationKeys {
    struct Source {
        static let entityId = "entityId"
        static let modelType = "modelType"
        static let readyToValidate = "readyToValidate"
    }
    
    struct Destination {
        static let entityId = Source.entityId
        static let modelTypeString = "modelTypeString"
        static let lifeCycleString = "lifeCycleString"
    }
}

@objc(FillEntityIdIfNilPolicy)
final class FillEntityIdIfNilPolicy: NSEntityMigrationPolicy {
    override func createDestinationInstances(forSource source: NSManagedObject,
                                             in mapping: NSEntityMapping,
                                             manager: NSMigrationManager) throws {
        Logger.drivers.logInfo("Starting FillEntityIdIfNilPolicy migration for mapping: \(mapping.name ?? "unknown")")
        
        guard let destName = mapping.destinationEntityName else {
            Logger.drivers.logWarning("No destination entity name found, skipping migration")
            return
        }
        let destination = NSEntityDescription.insertNewObject(forEntityName: destName,
                                                              into: manager.destinationContext)
        
        // copy all attributes except 'entityId'
        let attrs = source.entity.attributesByName.keys
        for key in attrs where ( key != MigrationKeys.Source.entityId &&
                                 key != MigrationKeys.Source.modelType &&
                                 key != MigrationKeys.Source.readyToValidate) {
            destination.setValue(source.value(forKey: key), forKey: key)
        }
        
        if let uuid = source.value(forKey: MigrationKeys.Source.entityId) as? UUID {
            Logger.drivers.logInfo("Copying existing entityId: \(uuid)")
            destination.setValue(uuid, forKey: MigrationKeys.Destination.entityId)
        } else {
            let newUUID = UUID()
            Logger.drivers.logInfo("Generating new entityId: \(newUUID) (source entityId was nil)")
            destination.setValue(newUUID, forKey: MigrationKeys.Destination.entityId)
        }
        
        if source.entity.attributesByName.keys.contains(MigrationKeys.Source.modelType),
           let model = source.value(forKey: MigrationKeys.Source.modelType) as? String {
            Logger.drivers.logInfo("Migrating modelType: \(model)")
            destination.setValue(model, forKey: MigrationKeys.Destination.modelTypeString)
        }
        
        if source.value(forKey: MigrationKeys.Source.readyToValidate) is Bool { /* removed */ }

        destination.setValue(CoreDataManageableState.ready.rawValue, forKey: MigrationKeys.Destination.lifeCycleString)
        
        manager.associate(sourceInstance: source, withDestinationInstance: destination, for: mapping)
        
        Logger.drivers.logInfo("Completed migration for entity \(destName)")
    }
}
