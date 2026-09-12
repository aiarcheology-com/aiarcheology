//
//  ModelAssetStore.swift
//  AI Archeology
//
//  Extracted from DeepState (AIA-0388): the asset half of a deleted configuration —
//  on-disk model files and their DownloadItem linkage.
//

import Foundation
import CoreData
import OSLog

/// Owns the filesystem + download-linkage side of a model configuration's lifecycle.
///
/// Split out of `DeepState` so the asset concern (FileManager + `DownloadItem`) is unit-testable
/// without the Core Data config repository or the driver runtime. Injected the SAME
/// `DataController` as the coordinator so `DownloadItem` reads/writes hit the one `viewContext`.
@MainActor
final class ModelAssetStore {
	private let dataController: DataController

	init(dataController: DataController) {
		self.dataController = dataController
	}

	/// Cleans up the on-disk assets for a deleted configuration. Mirrors the old
	/// `DeepState.handleDeletedConfigurations` asset half exactly:
	/// - **demo** models are bundled with the app → skip all asset work.
	/// - a config referenced by a `DownloadItem` (any state) keeps its file; if that item is
	///   `.imported`, transition it back to `.complete` and save (this save error is thrown so the
	///   coordinator can surface it — the only error this method reports).
	/// - a config with **no** linked `DownloadItem` → delete its model directory off the main
	///   actor (best-effort; file-deletion errors are logged, never thrown).
	func cleanup(entityId: UUID, demo: Bool) async throws {
		// Skip demo models - they're bundled with the app
		guard demo.not else {
			LoggingPolicy.debug("Skipping deletion of demo model for configuration \(entityId.uuidString)", logger: .state)
			return
		}

		// If referenced by a download item, transition it back to .complete and skip file deletion
		if let downloadItem = DownloadItem.select(entityId, in: dataController.container.viewContext) {
			if downloadItem.state == .imported {
				downloadItem.state = .complete
				try DownloadItem.save(in: dataController.container.viewContext)
				LoggingPolicy.debug("Transitioned download item to .complete for deleted configuration \(entityId.uuidString)", logger: .state)
			}
			LoggingPolicy.debug("Skipping deletion of model file still referenced by download item for configuration \(entityId.uuidString)", logger: .state)
			return
		}

		// Get directory path before offloading
		guard let configurationDirectory = FileManager.deepConfigurationDirectory(id: entityId)?.path(percentEncoded: false) else {
			LoggingPolicy.debug("Configuration directory path is nil for \(entityId.uuidString)", logger: .state)
			return
		}

		// Offload file deletion to background to avoid blocking MainActor
		Task.detached(priority: .utility) {
			let fileManager = FileManager.default

			guard fileManager.fileExists(atPath: configurationDirectory) else {
				LoggingPolicy.debug("Configuration directory does not exist for \(entityId.uuidString)", logger: .state)
				return
			}

			do {
				try fileManager.removeItem(atPath: configurationDirectory)
				LoggingPolicy.info("Model file successfully deleted for configuration \(entityId.uuidString)", logger: .state)
			} catch {
				LoggingPolicy.error("Error deleting model file for configuration \(entityId.uuidString): \(error.localizedDescription)", logger: .state)
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteModelFile", "configId": entityId.uuidString])
			}
		}
	}
}
