//
//  FillEntityIdIfNilPolicy.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 31.10.25.
//

import CoreData
import OSLog

// Migration from 0.0.0 to 0.0.1

private struct MigrationKeys {
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
		LoggingPolicy.info("Starting FillEntityIdIfNilPolicy migration for mapping: \(mapping.name ?? "unknown")", logger: .storage)
        
        guard let destName = mapping.destinationEntityName else {
			LoggingPolicy.warning("No destination entity name found, skipping migration", logger: .storage)
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
			LoggingPolicy.info("Copying existing entityId: \(uuid)", logger: .storage)
            destination.setValue(uuid, forKey: MigrationKeys.Destination.entityId)
        } else {
            let newUUID = UUID()
            LoggingPolicy.info("Generating new entityId: \(newUUID) (source entityId was nil)", logger: .storage)
            destination.setValue(newUUID, forKey: MigrationKeys.Destination.entityId)
        }
        
        if source.entity.attributesByName.keys.contains(MigrationKeys.Source.modelType),
           let model = source.value(forKey: MigrationKeys.Source.modelType) as? String {
			LoggingPolicy.info("Migrating modelType: \(model)", logger: .storage)
            destination.setValue(model, forKey: MigrationKeys.Destination.modelTypeString)
        }
        
        if source.value(forKey: MigrationKeys.Source.readyToValidate) is Bool { /* removed */ }

        destination.setValue(CoreDataManageableState.ready.rawValue, forKey: MigrationKeys.Destination.lifeCycleString)
        
        manager.associate(sourceInstance: source, withDestinationInstance: destination, for: mapping)
        
        LoggingPolicy.info("Completed migration for entity \(destName)", logger: .storage)
    }
}
