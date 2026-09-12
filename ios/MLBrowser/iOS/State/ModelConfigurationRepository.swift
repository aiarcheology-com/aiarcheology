//
//  ModelConfigurationRepository.swift
//  AI Archeology
//
//  Extracted from DeepState (AIA-0388): the Core Data configuration repository —
//  CRUD/fetch/reset over `DeepConfiguration`, with no driver-runtime or filesystem concern.
//

import Foundation
import CoreData

/// The Core Data repository for `DeepConfiguration` rows.
///
/// Split out of `DeepState` so the config concern is unit-testable against Core Data alone
/// (no drivers, no FileManager). Methods that can fail **throw**; the coordinator owns the single
/// `deepStateError` channel and surfaces them. Injected the SAME `DataController` as the
/// coordinator so writes fire `NSManagedObjectContextObjectsDidChange` on the one `viewContext`
/// the coordinator observes.
@MainActor
final class ModelConfigurationRepository {
	private let dataController: DataController

	init(dataController: DataController) {
		self.dataController = dataController
	}

	private var context: NSManagedObjectContext {
		dataController.container.viewContext
	}

	func create() -> DeepConfiguration {
		DeepConfiguration.create(in: context)
	}

	func update(
		_ entityId: UUID,
		with updateClosure: @Sendable @escaping (DeepConfiguration) -> Void
	) throws {
		try DeepConfiguration.update(entityId, in: context, with: updateClosure)
	}

	func delete(_ entityId: UUID) {
		guard let entity = select(entityId) else { return }
		delete(entity)
	}

	func delete(_ entity: DeepConfiguration) {
		let entityId = entity.entityId
		// Per-model presentation preferences live in UserDefaults — clear them with the row.
		entity.removePresentationDefaults()
		DeepConfiguration.delete(entity, in: context)
		if DownloadItem.select(entityId, in: context) == nil {
			CatalogSourceStore.removeSource(for: entityId)
		}
	}

	func select(_ entityId: UUID) -> DeepConfiguration? {
		DeepConfiguration.select(entityId, in: context)
	}

	func selectAll() -> [DeepConfiguration] {
		DeepConfiguration.selectAll(in: context)
	}

	func save() throws {
		try DeepConfiguration.save(in: context)
	}

	/// Deletes every configuration. Order is load-bearing: clear the per-model presentation defaults
	/// FIRST — the batch delete below bypasses per-entity delete hooks and leaves
	/// `selectAll()` empty afterwards, so clearing must precede it. Throws on delete failure so the
	/// coordinator can keep drivers registered and surface the error.
	func reset() async throws {
		let configurations = selectAll()
		let catalogSourceIDsToRemove = configurations.compactMap { configuration -> UUID? in
			configuration.removePresentationDefaults()
			return DownloadItem.select(configuration.entityId, in: context) == nil ? configuration.entityId : nil
		}
		// The viewContext reference is only handed to mergeChanges(fromRemoteContextSave:into:),
		// which is safe to call cross-queue.
		let viewContext = context
		let deleteError: Error? = await withCheckedContinuation { continuation in
			dataController.performBackgroundTask { context in
				do {
					// Merge into the viewContext too: batch deletes bypass context saves, so
					// automaticallyMergesChangesFromParent does NOT propagate them.
					try DeepConfiguration.deleteAll(in: context, mergingInto: [viewContext])
					continuation.resume(returning: nil)
				} catch {
					continuation.resume(returning: error)
				}
			}
		}

		if let deleteError {
			throw deleteError
		}
		catalogSourceIDsToRemove.forEach(CatalogSourceStore.removeSource)
	}
}
