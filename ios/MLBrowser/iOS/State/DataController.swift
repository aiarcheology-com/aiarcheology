//
//  DataController.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

@preconcurrency import CoreData
import SwiftUI
import OSLog
import Combine

@MainActor
final class DataController: ObservableObject {
	static let containerName = "MLBrowser"

	/// Shared managed object model to avoid loading duplicates in tests.
	/// Core Data has issues when the same model is loaded multiple times.
	/// Using nonisolated(unsafe) to ensure the model is loaded exactly once per process.
	nonisolated(unsafe) private static var _sharedModel: NSManagedObjectModel?
	nonisolated(unsafe) private static let modelLock = NSLock()

	private static var sharedModel: NSManagedObjectModel {
		modelLock.lock()
		defer { modelLock.unlock() }

		if let model = _sharedModel {
			return model
		}

		// Try main bundle first, then fall back to searching all bundles (for tests)
		let modelURL = Bundle.main.url(forResource: containerName, withExtension: "momd")
			?? Bundle.allBundles.compactMap { $0.url(forResource: containerName, withExtension: "momd") }.first

		guard let url = modelURL, let model = NSManagedObjectModel(contentsOf: url) else {
			fatalError("Failed to load Core Data model '\(containerName).momd'")
		}

		_sharedModel = model
		return model
	}

	private(set) var container: NSPersistentContainer

	/// Indicates whether the persistent store has been successfully loaded
	@Published private(set) var isStoreLoaded = false

	/// Executes work on a background context asynchronously.
	///
	/// **Important**: Although `DataController` is marked `@MainActor`, the `block` parameter
	/// runs on a background thread managed by Core Data. Do not access `@MainActor`-isolated
	/// properties from within the block without proper synchronization.
	///
	/// Changes are automatically merged to `viewContext` after save.
	///
	/// - Parameters:
	///   - mergePolicy: The merge policy to apply to the background context.
	///                  Defaults to `.mergeByPropertyObjectTrump`, which means
	///                  in-memory changes win over persistent store changes.
	///                  This is appropriate for isolated updates where the most
	///                  recent changes should take precedence. For operations where
	///                  store changes should win (e.g., destructive operations),
	///                  consider using `.mergeByPropertyStoreTrump`.
	///   - block: The work to perform on the configured background context.
	func performBackgroundTask(
		mergePolicy: NSMergePolicy = .mergeByPropertyObjectTrump,
		_ block: @escaping @Sendable (NSManagedObjectContext) -> Void
	) {
		container.performBackgroundTask { context in
			context.mergePolicy = mergePolicy
			block(context)
		}
	}

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: DataController.containerName, managedObjectModel: Self.sharedModel)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else if let desc = container.persistentStoreDescriptions.first {
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = false
        }

		loadStores()
	}

	/// Initializer for testing with a custom store URL (e.g., temporary SQLite store).
	init(storeURL: URL) {
		container = NSPersistentContainer(name: DataController.containerName, managedObjectModel: Self.sharedModel)
		let description = NSPersistentStoreDescription(url: storeURL)
		description.shouldMigrateStoreAutomatically = true
		description.shouldInferMappingModelAutomatically = true
		container.persistentStoreDescriptions = [description]
		loadStores()
	}

	private func loadStores() {
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
		// Set explicit merge policy to ensure consistent conflict resolution
		// across all contexts (background contexts also use mergeByPropertyObjectTrump by default)
		container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
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
