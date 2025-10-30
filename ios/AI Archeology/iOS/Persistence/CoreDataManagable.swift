//
//  CoreDataManagable.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

@preconcurrency import CoreData
import OSLog

protocol CoreDataManageable where Self: NSManagedObject {
	var entityId: UUID { get }
	static func create(in context: NSManagedObjectContext) -> Self
	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void)
	static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool)
	static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
	static func delete(_ entity: Self, in context: NSManagedObjectContext)
	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self?
    static func selectAll(in context: NSManagedObjectContext) -> [Self]
	static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
	static func create(in context: NSManagedObjectContext) -> Self {
        Logger.persistence.logDebug("Creating new \(String(describing: Self.self)) entity")
        return Self(context: context)
	}

	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void) {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)
        
        do {
            let objects = try context.fetch(request) as? [Self]
            guard let count = objects?.count else {
                Logger.persistence.logError("Failed to fetch objects for update - unexpected nil result for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            if count != 1 {
                Logger.persistence.logWarning("Expected 1 instance for update but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
            }
            
            guard let objectToUpdate = objects?.first else {
                Logger.persistence.logWarning("No object found to update for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            updateClosure(objectToUpdate)
            
            
            save(in: context) //'async' call in a function that does not support concurrency
            
            Logger.persistence.logDebug("Successfully updated \(String(describing: Self.self)) entity with ID \(entityId.uuidString)")
        } catch {
            Logger.persistence.logError("Update error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "update", "entityType": String(describing: Self.self)])
        }
	}

	static func save(in context: NSManagedObjectContext) {
        do {
            if context.hasChanges {
                try context.save()
                Logger.persistence.logDebug("Successfully saved context changes for \(String(describing: Self.self))")
            }
        } catch {
            Logger.persistence.logError("CoreData save error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "save", "entityType": String(describing: Self.self)])
        }
	}

	static func delete(_ entity: Self, in context: NSManagedObjectContext) {
        let objectID = entity.objectID
        do {
            let entityToDelete = try context.existingObject(with: objectID)
            Logger.persistence.logDebug("Deleting \(String(describing: Self.self)) entity")
            context.delete(entityToDelete)
            save(in: context) //'async' call in a function that does not support concurrency
            Logger.persistence.logInfo("Successfully deleted \(String(describing: Self.self)) entity")
        } catch {
            Logger.persistence.logError("Error fetching object for deletion \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
        }
	}

	static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool = false) {
		let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Self.fetchRequest()
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        do {
            if executeAndMerge.enabled {
                try context.executeAndMergeChanges(using: deleteRequest)
            } else {
                try context.execute(deleteRequest)
            }
            
            save(in: context)
            Logger.persistence.logInfo("Successfully deleted all \(String(describing: Self.self)) entities")
        } catch {
            Logger.persistence.logError("Error deleting all entities \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteAll", "entityType": String(describing: Self.self)])
        }
	}

	static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

        do {
            let objects = try context.fetch(request) as? [Self]
            guard let objectToDelete = objects?.first else {
                Logger.persistence.logDebug("No object found to delete for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            context.delete(objectToDelete)
            save(in: context)
            Logger.persistence.logDebug("Successfully deleted \(String(describing: Self.self)) entity with ID \(entityId.uuidString)")
        } catch {
            Logger.persistence.logError("Deletion error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
        }
	}

	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)
        
        nonisolated(unsafe) var result: Self?
        do {
            let objects = try context.fetch(request) as? [Self]
            let count = objects?.count ?? 0
            
            if count > 1 {
                Logger.persistence.logWarning("Expected at most 1 instance but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
            }
            
            result = objects?.first //Capture of 'result' with non-Sendable type 'Self?' in a '@Sendable' closure
        } catch {
            Logger.persistence.logError("Error fetching object \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "select", "entityType": String(describing: Self.self)])
        }
        return result
	}

	static func selectAll(in context: NSManagedObjectContext) -> [Self] {
        let request = Self.fetchRequest()
        
        nonisolated(unsafe) var result: [Self] = []
        do {
            let objects = try context.fetch(request) as? [Self]
            Logger.persistence.logDebug("Fetched \((objects?.count ?? 0)) \(String(describing: Self.self)) entities")
            result = objects ?? []
        } catch {
            Logger.persistence.logError("Error fetching all objects \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "getAll", "entityType": String(describing: Self.self)])
        }
        return result
	}
}
