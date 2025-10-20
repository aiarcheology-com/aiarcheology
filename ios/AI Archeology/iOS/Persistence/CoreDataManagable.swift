//
//  CoreDataManagable.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import CoreData
import OSLog

protocol CoreDataManageable where Self: NSManagedObject {
	var entityId: UUID? { get }
	static func create(in context: NSManagedObjectContext) -> Self
	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void)
	static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool)
	static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
	static func delete(_ entity: Self, in context: NSManagedObjectContext)
	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self?
	static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
	static func create(in context: NSManagedObjectContext) -> Self {
		Logger.persistence.logDebug("Creating new \(String(describing: Self.self), privacy: .public) entity")
		return Self(context: context)
	}

	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				guard let count = objects?.count else {
					Logger.persistence.logError("Failed to fetch objects for update - unexpected nil result for entity \(String(describing: Self.self), privacy: .public) with ID \(entityId.uuidString, privacy: .public)")
					return
				}
				
				if count != 1 {
					Logger.persistence.logWarning("Expected 1 instance for update but found \(count) for entity \(String(describing: Self.self), privacy: .public) with ID \(entityId.uuidString, privacy: .public)")
				}
				
				guard let objectToUpdate = objects?.first else {
					Logger.persistence.logWarning("No object found to update for entity \(String(describing: Self.self), privacy: .public) with ID \(entityId.uuidString, privacy: .public)")
					return
				}
				
				updateClosure(objectToUpdate)
				Self.save(in: context)
				Logger.persistence.logDebug("Successfully updated \(String(describing: Self.self), privacy: .public) entity with ID \(entityId.uuidString, privacy: .public)")
			} catch {
				Logger.persistence.logError("Update error for \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "update", "entityType": String(describing: Self.self)])
			}
		}
	}

	static func save(in context: NSManagedObjectContext) {
		if context.hasChanges {
			do {
				try context.save()
				Logger.persistence.logDebug("Successfully saved context changes for \(String(describing: Self.self), privacy: .public)")
			} catch {
				Logger.persistence.logError("CoreData save error for \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "save", "entityType": String(describing: Self.self)])
			}
		}
	}

	static func delete(_ entity: Self, in context: NSManagedObjectContext) {
		Logger.persistence.logDebug("Deleting \(String(describing: Self.self), privacy: .public) entity")
		context.delete(entity)
		do {
			try context.save()
			Logger.persistence.logDebug("Successfully deleted \(String(describing: Self.self), privacy: .public) entity")
		} catch {
			Logger.persistence.logError("Error deleting entity \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
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

			try context.save()
			Logger.persistence.logInfo("Successfully deleted all \(String(describing: Self.self), privacy: .public) entities")
		} catch {
			Logger.persistence.logError("Error deleting all entities \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteAll", "entityType": String(describing: Self.self)])
		}
	}

	static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				guard let objectToDelete = objects?.first else {
					Logger.persistence.logDebug("No object found to delete for entity \(String(describing: Self.self), privacy: .public) with ID \(entityId.uuidString, privacy: .public)")
					return
				}
				
				context.delete(objectToDelete)
				Self.save(in: context)
				Logger.persistence.logDebug("Successfully deleted \(String(describing: Self.self), privacy: .public) entity with ID \(entityId.uuidString, privacy: .public)")
			} catch {
				Logger.persistence.logError("Deletion error for \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
			}
		}
	}

	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		do {
			let objects = try context.fetch(request) as? [Self]
			let count = objects?.count ?? 0
			
			if count > 1 {
				Logger.persistence.logWarning("Expected at most 1 instance but found \(count) for entity \(String(describing: Self.self), privacy: .public) with ID \(entityId.uuidString, privacy: .public)")
			}
			
			return objects?.first
		} catch {
			Logger.persistence.logError("Error fetching object \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "select", "entityType": String(describing: Self.self)])
			return nil
		}
	}

	static func getAll(in context: NSManagedObjectContext) -> [Self] {
		let request = Self.fetchRequest()

		do {
			let objects = try context.fetch(request) as? [Self]
			Logger.persistence.logDebug("Fetched \((objects?.count ?? 0)) \(String(describing: Self.self), privacy: .public) entities")
			return objects ?? []
		} catch {
			Logger.persistence.logError("Error fetching all objects \(String(describing: Self.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
			DefaultCrashReporter.shared.recordError(error, context: ["operation": "getAll", "entityType": String(describing: Self.self)])
			return []
		}
	}
}
