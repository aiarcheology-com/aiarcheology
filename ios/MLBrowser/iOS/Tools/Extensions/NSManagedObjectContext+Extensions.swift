//
//  NSManagedObjectContext+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 05.12.23.
//

import CoreData

// https://stackoverflow.com/a/60266079/3389683
extension NSManagedObjectContext {

		/// Executes the given `NSBatchDeleteRequest` and directly merges the changes to bring the given managed object context up to date.
		///
		/// - Parameter batchDeleteRequest: The `NSBatchDeleteRequest` to execute.
		/// - Throws: An error if anything went wrong executing the batch deletion.
	public func executeAndMergeChanges(using batchDeleteRequest: NSBatchDeleteRequest) throws {
		batchDeleteRequest.resultType = .resultTypeObjectIDs
		let result = try execute(batchDeleteRequest) as? NSBatchDeleteResult
		let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: result?.result as? [NSManagedObjectID] ?? []]
		NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self])
	}
}
