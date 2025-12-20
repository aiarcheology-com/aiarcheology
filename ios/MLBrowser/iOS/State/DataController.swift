//
//  DataController.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import CoreData
import SwiftUI
import OSLog
import Combine

@MainActor
final class DataController: ObservableObject {
	static let containerName = "MLBrowser"
	private(set) var container: NSPersistentContainer

	/// Indicates whether the persistent store has been successfully loaded
	@Published private(set) var isStoreLoaded = false

	/// Executes work on a background context asynchronously.
	/// Changes are automatically merged to viewContext after save.
	/// - Parameter block: The work to perform on the background context
	func performBackgroundTask(_ block: @escaping @Sendable (NSManagedObjectContext) -> Void) {
		container.performBackgroundTask { context in
			context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
			block(context)
		}
	}

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: DataController.containerName)
        
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else if let desc = container.persistentStoreDescriptions.first {
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = false
        }
        
		container.loadPersistentStores { [weak self] description, error in
			if let error = error {
				// Core Data failure is a critical error that compromises all app functionality
				LoggingPolicy.fault("Core Data failed to load persistent store: \(error.localizedDescription)", logger: .persistence)
				LoggingPolicy.criticalFailure("Core Data persistent store failed to load: \(error.localizedDescription)")
			} else {
				LoggingPolicy.debug("Core Data persistent store loaded successfully: \(description.description)")
				if Thread.isMainThread {
					self?.setupContextMerging()
					self?.isStoreLoaded = true
				} else {
					DispatchQueue.main.async {
						self?.setupContextMerging()
						self?.isStoreLoaded = true
					}
				}
			}
		}
	}

	/// Sets up automatic merging of changes from background contexts to viewContext
	private func setupContextMerging() {
		// Automatically merge changes from background contexts into viewContext
		container.viewContext.automaticallyMergesChangesFromParent = true
		LoggingPolicy.debug("Core Data context merging enabled", logger: .persistence)
	}
	
	/// Async wrapper that waits for store to be ready
	func awaitStoreReady() async {
		guard !isStoreLoaded else { return }
		
		await withCheckedContinuation { continuation in
			var cancellable: AnyCancellable?
			cancellable = $isStoreLoaded
				.filter { $0 }
				.first()
				.sink { _ in
					continuation.resume()
					cancellable?.cancel()
				}
		}
	}
}
