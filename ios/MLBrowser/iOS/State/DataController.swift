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
	///
	/// Using nonisolated(unsafe) for _sharedModel is safe here because NSLock provides
	/// proper synchronization guarantees. The lock ensures only one thread can access
	/// and modify _sharedModel at a time, preventing data races even though we bypass
	/// Swift's concurrency checking with nonisolated(unsafe).
	///
	/// This approach is necessary because the model needs to be accessed from @MainActor-isolated
	/// initializers while being shared across all DataController instances to prevent duplicate
	/// entity descriptions that cause crashes in parallel test execution.
	nonisolated(unsafe) private static var _sharedModel: NSManagedObjectModel?
	private static let modelLock = NSLock()

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

	/// Tracks whether we've already destroyed and reloaded the store after a migration failure.
	///
	/// This flag is intentionally scoped to the lifetime of a `DataController` instance
	/// (i.e., a single app session) rather than to a single migration attempt. This ensures
	/// that we perform at most one destructive "destroy and recreate store" recovery per
	/// controller lifetime, preventing potential infinite retry loops if the store continues
	/// to fail migration or loading for non-transient reasons. During development, if the
	/// data model changes multiple times in one run, subsequent migration failures will not
	/// trigger another destructive recovery and will instead surface the error.
	private var didRetryAfterStoreDestruction = false

	/// Determines whether Core Data should automatically infer mapping models for migrations.
	///
	/// - Returns: `true` for TestFlight/dev builds to enable automatic lightweight migration,
	///            `false` for App Store and Debug builds to enforce strict migration requirements.
	///
	/// **Note**: Core Data tries explicit mapping models (`.xcmappingmodel`) first, then falls
	/// back to inferred migration. Custom migration policies (e.g., `FillEntityIdIfNilPolicy`)
	/// will still be used when applicable.
	private var shouldInferMappingModelAutomatically: Bool {
		!(AppEnvironment.isAppStoreDistribution || AppEnvironment.isDebugConfiguration)
	}

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
        } else if AppEnvironment.isRunningUITests {
            // UI tests run against a dedicated, disposable store so every launch starts from a
            // clean, demo-seeded baseline — the Core Data analogue of the ephemeral UserDefaults
            // suite (AIA-0298). The production store is never touched. Destroy any prior UI-test
            // store first (WAL/SHM-safe via the coordinator, not a raw file delete), then the
            // fresh load below recreates it empty and DemoDataManager reseeds it.
            let description = Self.uiTestStoreDescription()
            container.persistentStoreDescriptions = [description]
            destroyUITestStore(description)
        } else if let desc = container.persistentStoreDescriptions.first {
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = shouldInferMappingModelAutomatically
        }

		loadStores()
	}

	/// Initializer for testing with a custom store URL (e.g., temporary SQLite store).
	init(storeURL: URL) {
		container = NSPersistentContainer(name: DataController.containerName, managedObjectModel: Self.sharedModel)
		let description = NSPersistentStoreDescription(url: storeURL)
		description.shouldMigrateStoreAutomatically = true
		// Tests always use automatic inference for simplicity
		description.shouldInferMappingModelAutomatically = true
		container.persistentStoreDescriptions = [description]
		loadStores()
	}

	/// Store description for UI-test runs: a dedicated SQLite file in Caches, kept separate from
	/// the real store so tests never read or clobber production data.
	private static func uiTestStoreDescription() -> NSPersistentStoreDescription {
		let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		let storeURL = cachesURL.appendingPathComponent("UITests-\(containerName).sqlite")
		let description = NSPersistentStoreDescription(url: storeURL)
		description.shouldMigrateStoreAutomatically = true
		description.shouldInferMappingModelAutomatically = true
		return description
	}

	/// Destroys the UI-test store before loading so each launch starts empty. Uses the
	/// coordinator's `destroyPersistentStore` (handles WAL/SHM) rather than deleting the bare
	/// `.sqlite`, which would leak the sidecar files and yield a half-empty store next launch.
	private func destroyUITestStore(_ description: NSPersistentStoreDescription) {
		guard let storeURL = description.url else { return }
		do {
			try container.persistentStoreCoordinator.destroyPersistentStore(
				at: storeURL,
				ofType: description.type,
				options: description.options
			)
		} catch {
			LoggingPolicy.error("Failed to destroy UI-test store: \(error.localizedDescription)", logger: .persistence)
		}
	}

	private func loadStores() {
		container.loadPersistentStores { [weak self] description, error in
			guard let self = self else { return }

			if let error = error {
				self.handleStoreLoadError(error, description: description)
			} else {
				LoggingPolicy.debug("Core Data persistent store loaded successfully: \(description.description)")
				if Thread.isMainThread {
					self.setupContextMerging()
					self.isStoreLoaded = true
				} else {
					DispatchQueue.main.async {
						self.setupContextMerging()
						self.isStoreLoaded = true
					}
				}
			}
		}
	}

	/// Handles Core Data store load errors with optional recovery for migration issues
	private func handleStoreLoadError(_ error: Error, description: NSPersistentStoreDescription) {
		let nsError = error as NSError

		// Check if this is a migration-related error
		let isMigrationError = nsError.domain == NSCocoaErrorDomain && (
			nsError.code == NSPersistentStoreIncompatibleVersionHashError || // 134100
			nsError.code == NSMigrationMissingSourceModelError ||            // 134130
			nsError.code == NSMigrationMissingMappingModelError ||           // 134140
			nsError.code == NSMigrationError ||              				 // 134110
			nsError.code == NSPersistentStoreIncompatibleSchemaError         // 134020
		)

		// Only attempt recovery in non-App Store builds
		let canAttemptRecovery = !AppEnvironment.isAppStoreDistribution &&
								 isMigrationError &&
								 !didRetryAfterStoreDestruction

		if canAttemptRecovery {
			LoggingPolicy.warning(
				"Core Data migration error detected (code: \(nsError.code)). Attempting to destroy and recreate store: \(error.localizedDescription)",
				logger: .persistence
			)
			destroyAndRetryStore(description: description)
		} else {
			// Critical failure - either App Store build or retry already attempted
			LoggingPolicy.fault("Core Data failed to load persistent store: \(error.localizedDescription)", logger: .persistence)

			if didRetryAfterStoreDestruction {
				LoggingPolicy.criticalFailure("Core Data persistent store failed to load even after store destruction: \(error.localizedDescription)")
			} else {
				LoggingPolicy.criticalFailure("Core Data persistent store failed to load: \(error.localizedDescription)")
			}
		}
	}

	/// Destroys the persistent store and retries loading with a fresh container (TestFlight/dev recovery path)
	private func destroyAndRetryStore(description: NSPersistentStoreDescription) {
		didRetryAfterStoreDestruction = true

		guard let storeURL = description.url else {
			LoggingPolicy.error("Cannot destroy store: no URL found in description", logger: .persistence)
			LoggingPolicy.criticalFailure("Core Data recovery failed: no store URL")
		}

		do {
			// Destroy the persistent store (this handles all cleanup including WAL/SHM files)
			try container.persistentStoreCoordinator.destroyPersistentStore(
				at: storeURL,
				ofType: description.type,
				options: description.options
			)

			LoggingPolicy.info("Successfully destroyed Core Data store. Creating fresh container and retrying load...", logger: .persistence)

			DispatchQueue.main.async { [weak self] in
				guard let self = self else { return }

				// Create a fresh container to avoid contaminated coordinator state
				self.container = NSPersistentContainer(
					name: DataController.containerName,
					managedObjectModel: Self.sharedModel
				)

				// Reapply the same configuration
				if let desc = self.container.persistentStoreDescriptions.first {
					desc.shouldMigrateStoreAutomatically = true
					desc.shouldInferMappingModelAutomatically = shouldInferMappingModelAutomatically
				}
                                
				// Retry loading with fresh container
				self.loadStores()
			}
		} catch {
			LoggingPolicy.error("Failed to destroy persistent store: \(error.localizedDescription)", logger: .persistence)
			// Reset flag since destruction failed - allows retry if another error occurs in this session
			didRetryAfterStoreDestruction = false
			LoggingPolicy.criticalFailure("Cannot recover from Core Data migration failure: \(error.localizedDescription)")
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
            // swiftlint:disable:next first_where
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
