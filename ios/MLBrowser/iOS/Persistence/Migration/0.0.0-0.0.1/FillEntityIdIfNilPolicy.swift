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

enum MigrationError: Error {
    case missingDestinationEntityName(mapping: String)
}

@objc(FillEntityIdIfNilPolicy)
final class FillEntityIdIfNilPolicy: NSEntityMigrationPolicy {
    override func createDestinationInstances(forSource source: NSManagedObject,
                                             in mapping: NSEntityMapping,
                                             manager: NSMigrationManager) throws {
		LoggingPolicy.info("Starting FillEntityIdIfNilPolicy migration for mapping: \(mapping.name ?? "unknown")", logger: .storage)

        guard let destName = mapping.destinationEntityName else {
            // Silently dropping the source row would lose user data; fail the migration instead.
            LoggingPolicy.error("No destination entity name found for mapping \(mapping.name ?? "unknown")", logger: .storage)
            throw MigrationError.missingDestinationEntityName(mapping: mapping.name ?? "unknown")
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
        
        // Lifecycle: legacy rows may be incomplete (nil file, missing model type, ...).
        // Setting .ready unconditionally makes validateForInsert() throw at migration save,
        // which fails the WHOLE migration — in App Store builds that is an unrecoverable
        // crash loop. Only promote rows that actually pass validation; park the rest in .draft.
        let legacyReadyToValidate = source.value(forKey: MigrationKeys.Source.readyToValidate) as? Bool

        if legacyReadyToValidate == false {
            destination.setValue(CoreDataManageableState.draft.rawValue, forKey: MigrationKeys.Destination.lifeCycleString)
        } else {
            destination.setValue(CoreDataManageableState.ready.rawValue, forKey: MigrationKeys.Destination.lifeCycleString)
            if let stateful = destination as? any CoreDataManagableWithState,
               stateful.validationReport().isValid.not {
                LoggingPolicy.warning("Migrated \(destName) row would fail .ready validation; downgrading to .draft", logger: .storage)
                destination.setValue(CoreDataManageableState.draft.rawValue, forKey: MigrationKeys.Destination.lifeCycleString)
            }
        }

        manager.associate(sourceInstance: source, withDestinationInstance: destination, for: mapping)
        
        LoggingPolicy.info("Completed migration for entity \(destName)", logger: .storage)
    }
}
