//
//  NSManagedObjectContext+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 05.12.23.
//

import CoreData

// https://stackoverflow.com/a/60266079/3389683
extension NSManagedObjectContext {

		/// Executes the given `NSBatchDeleteRequest` and directly merges the changes to bring the given managed object contexts up to date.
		///
		/// Batch deletes operate directly on the persistent store and bypass context saves, so
		/// `automaticallyMergesChangesFromParent` does NOT propagate them. Every context that may
		/// hold references to the deleted objects (typically the viewContext) must be merged into
		/// explicitly, otherwise it retains zombie objects that can be re-inserted on its next save.
		///
		/// - Parameters:
		///   - batchDeleteRequest: The `NSBatchDeleteRequest` to execute.
		///   - additionalContexts: Other contexts (e.g. the viewContext) to merge the deletions into.
		/// - Throws: An error if anything went wrong executing the batch deletion.
	public func executeAndMergeChanges(using batchDeleteRequest: NSBatchDeleteRequest, into additionalContexts: [NSManagedObjectContext] = []) throws {
		batchDeleteRequest.resultType = .resultTypeObjectIDs
		let result = try execute(batchDeleteRequest) as? NSBatchDeleteResult
		let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: result?.result as? [NSManagedObjectID] ?? []]
		NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self] + additionalContexts)
	}
}
