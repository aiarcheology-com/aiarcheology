//
//  FillEntityIdIfNilPolicy.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 31.10.25.
//

import CoreData
import OSLog

// The custom policy for migrations that must preserve (or repair) legacy entity ids. It lives beside
// the mapping-model folders because both direct paths to the current schema resolve it by the
// `@objc` name below, never by path.
//
// Migrations are single-hop: Core Data matches one mapping to the (store version, current model)
// pair and never composes two. So a new model version needs a mapping from every still-live source
// model, and each direct path assigns this policy to WebHistoryEntry, DeepConfiguration and
// DownloadItem, replacing the whole per-row copy below.

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
        
        // 0.0.0 had `readyToValidate` but no persisted lifecycle, so derive a safe lifecycle from
        // that field. 0.0.1 already has `lifeCycleString`; it was copied above and must be left
        // intact. Reading a key which its source model does not contain throws an Objective-C KVC
        // exception, so the schema check is essential for the direct 0.0.1→0.0.2 migration.
        if source.entity.attributesByName[MigrationKeys.Source.readyToValidate] != nil {
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
        }

        manager.associate(sourceInstance: source, withDestinationInstance: destination, for: mapping)
        
        LoggingPolicy.info("Completed migration for entity \(destName)", logger: .storage)
    }
}
