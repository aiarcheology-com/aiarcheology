//
//  CoreDataManagable.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import CoreData

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
		// TODO: pull some repeated lines out
	static func create(in context: NSManagedObjectContext) -> Self {
		return Self(context: context)
	}

	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				assert(objects?.count == 1, "The numbner of instances should be one.")
				let objectToUpdate = objects?.first
				if let objectToUpdate {
					updateClosure(objectToUpdate)
					Self.save(in: context)
				}
			} catch {
				assert(false, "Update error: \(error)")
			}
		}
	}

	static func save(in context: NSManagedObjectContext) {
		if context.hasChanges {
			do {
				try context.save()
			} catch let error as NSError {
				print("CoreData save error: \(error)")
					// objects, that are not valid, do not save
			}
		}
	}

	static func delete(_ entity: Self, in context: NSManagedObjectContext) {
		context.delete(entity)
		do {
			try context.save()
		}
		catch let error {
			print("Error deleting a single entity: \(error)")
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
		} catch let error as NSError {
			print("Error deleting all entities: \(error), \(error.userInfo)")
		}
	}

	static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				assert(objects?.count == 1, "The numbner of instances should be one.")
				let objectToDelete = objects?.first
				if let objectToDelete {
					context.delete(objectToDelete)
					Self.save(in: context)
				}
			} catch {
				assert(false, "Deletion error: \(error)")
			}
		}
	}

	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		do {
			let objects = try context.fetch(request) as? [Self]
			assert(objects?.count == 1, "The numbner of instances should be one.")
			return objects?.first
		} catch {
			assert(false, "Error fetching object: \(error)")
			return nil
		}
	}

	static func getAll(in context: NSManagedObjectContext) -> [Self] {
		let request = Self.fetchRequest()

		do {
			let objects = try context.fetch(request) as? [Self]
			return objects ?? []
		} catch {
			assert(false, "Error fetching all objects: \(error)")
			return []
		}
	}
}
