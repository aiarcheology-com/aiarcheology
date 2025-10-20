//
//  DeepState.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import CoreData
import Vision
import SwiftUI
import Combine
import OSLog

	// Drivers, DeepConfigurations, and DownloadItems have 1:1 relationship, and also
	// their entities have the same UUID. DeepConfiguations and DownloadItems are kept in CoreData.
	// Drivers are loaded on-demand in memory and un/registered with toggling the DeepConfiguration.enabled property.
final class DeepState: ObservableObject {
	unowned var appState: AppState
	var frame: CGRect = .zero

	@Published var newConfiguration: DeepConfiguration?
	@Published var deepStateError: Error?
	var drivers = DeepDrivers()

	init(appState: AppState) {
		self.appState = appState
		observeDeepConfigurationChanges()

		let configurations = DeepConfiguration.getAll(in: appState.dataController.container.viewContext)
		do {
			try configurations.forEach { config in
				guard config.enabled == true else { return }
				guard let driver = try self.createDriver(from: config) else { return }

				Task {
					do {
						try await driver.loadFile()
						register(driver: driver, along: config.modelTypeInternal)
						Logger.drivers.logInfo("Driver successfully loaded and registered for configuration \(config.entityId?.uuidString ?? "unknown")")
					}
					catch {
						Logger.drivers.logError("Failed to load driver for configuration \(config.entityId?.uuidString ?? "unknown"): \(error.localizedDescription)")
						DefaultCrashReporter.shared.recordError(error, context: ["operation": "loadDriver", "configId": config.entityId?.uuidString ?? "unknown"])
						deepStateError = error
					}
				}
			}
		}
		catch {
			// Send it to the upper layers to show the error to the user
			Logger.state.logError("Error initializing DeepState: \(error.localizedDescription)")
			deepStateError = error
		}
	}

	private func createDriver(from configuration: DeepConfiguration) throws -> (any DeepDriver)? {
		guard let entityId = configuration.entityId else {
			Logger.drivers.logError("Configuration entityId is nil when creating driver")
			return nil
		}
		
		Logger.drivers.logDebug("Creating driver of type \(configuration.modelTypeInternal.rawValue) for configuration \(entityId.uuidString)")
		
		switch configuration.modelTypeInternal {
			case .detector: return Detector(configuration: configuration, entityId: entityId)
			case .classificator: return Classificator(configuration: configuration, entityId: entityId)
		}
	}

		// Actions:
	private func register(driver: any DeepDriver, along: DeepDriverType) {
		drivers.register(driver: driver, along: along)
	}

	private func updaterDriver(with configuration: DeepConfiguration) {
		guard configuration.entityId != nil else {
			Logger.drivers.logError("Cannot update driver: Configuration.entityId is nil")
			return
		}
		drivers.update(configuration: configuration)
	}

	private func unregisterDriver(with configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else { return }
		drivers.unregister(driverId: entityId)
	}

	func createConfiguration() -> DeepConfiguration {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.create(in: context)
	}

	func updateConfiguration(_ entityId: UUID, updateClosure: (DeepConfiguration) -> Void) {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.update(entityId, in: context, with: updateClosure)
	}

	func deleteConfiguration(_ entityId: UUID) {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.delete(entityId, in: context)
	}

	func deleteConfiguration(_ entity: DeepConfiguration) {
		let context = appState.dataController.container.viewContext
		context.delete(entity)
	}

	func reset() {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.deleteAll(in: context)
	}

	func selectConfiguration(_ entityId: UUID) -> DeepConfiguration? {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.select(entityId, in: context)
	}

	func saveConfigurations() {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.save(in: context)
	}

	func allConfigurations() -> [DeepConfiguration] {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.getAll(in: context)
	}

		// Handlers:
	private var context: NSManagedObjectContext {
		appState.dataController.container.viewContext
	}
	private var deepConfigurationsChanges: AnyCancellable?

	private func observeDeepConfigurationChanges() {
		deepConfigurationsChanges = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
			.sink { [weak self] notification in
				self?.handleContextChanges(notification)
			}
	}

	private func handleContextChanges(_ notification: Notification) {
		guard let userInfo = notification.userInfo else { return }

		let insertedObjects = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in insertedObjects.compactMap({ $0 as? DeepConfiguration }) {
			do {
				if config.enabled, config.entityId.isNotNil {
					guard let driver = try createDriver(from: config) else {
						Logger.drivers.logError("Driver initialization failed after configuration insert for config \(config.entityId?.uuidString ?? "unknown")")
						return
					}

					let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
                        guard let id = config.entityId else { return false }
						return $0.id == id
					}

					if isDriverForThisConfigurationLoaded {
						Logger.drivers.logWarning("Attempting to insert configuration with UUID that already exists: \(config.entityId?.uuidString ?? "unknown")")
					}

					Task {
						do {
							try await driver.loadFile()
							register(driver: driver, along: config.modelTypeInternal)
							Logger.drivers.logInfo("Driver loaded and registered after configuration insert")
						}
						catch {
							Logger.drivers.logError("Failed to load driver after configuration insert: \(error.localizedDescription)")
							DefaultCrashReporter.shared.recordError(error, context: ["operation": "insertDriver", "configId": config.entityId?.uuidString ?? "unknown"])
							deepStateError = error
						}
					}
				}
			}
			catch {
				Logger.state.logError("Error handling configuration insert: \(error.localizedDescription)")
				deepStateError = error
			}
				//else: The configuration is going to be updated yet.
		}

		let updatedObjects = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in updatedObjects.compactMap({ $0 as? DeepConfiguration }) {
			do {
				guard config.entityId.isNotNil else {
					Logger.drivers.logError("Configuration update attempted with nil entityId")
					continue
				}
				let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
                    guard let id = config.entityId else { return false }
					return $0.id == id
				}
				if isDriverForThisConfigurationLoaded.not, config.enabled {
					guard let driver = try createDriver(from: config) else {
						Logger.drivers.logError("Driver initialization failed after configuration update for config \(config.entityId?.uuidString ?? "unknown")")
						return
					}
					Task {
						do {
							try await driver.loadFile()
							register(driver: driver, along: config.modelTypeInternal)
							Logger.drivers.logInfo("Driver loaded and registered after configuration update")
						}
						catch {
							Logger.drivers.logError("Failed to load driver after configuration update: \(error.localizedDescription)")
							DefaultCrashReporter.shared.recordError(error, context: ["operation": "updateDriver", "configId": config.entityId?.uuidString ?? "unknown"])
							deepStateError = error
						}
					}
				} else {
					if config.enabled {
						updaterDriver(with: config)
					} else {
						unregisterDriver(with: config)
					}

				}
			}
			catch {
				Logger.state.logError("Error handling configuration update: \(error.localizedDescription)")
				deepStateError = error
			}
		}

		let deletedObjects = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in deletedObjects.compactMap({ $0 as? DeepConfiguration }) {
			unregisterDriver(with: config)

				// Delete the model file:
			let fileManager = FileManager.default
			guard let entityId = config.entityId else {
				Logger.state.logWarning("Cannot reconstruct path to configuration directory: entityId is nil")
				return
			}

			guard
				let configurationDirectory = FileManager.deepConfigurationDirectory(id: entityId)?.path(percentEncoded: false),
				fileManager.fileExists(atPath: configurationDirectory)
			else {
				Logger.state.logDebug("Configuration directory does not exist or path is nil for \(entityId.uuidString)")
				return
			}

			guard config.demo.not else {
				// 1. DO NOT DELETE THE MODEL that is part of the demo
				Logger.state.logDebug("Skipping deletion of demo model for configuration \(entityId.uuidString)")
				return
			}

			guard DownloadItem.select(entityId, in: appState.dataController.container.viewContext).isNil else {
				// 2. DO NOT DELETE THE MODEL that is part of the existing download item
				// An alternative solution: having the models in a separate pre-import directory. But that consumes double of the storage.
				Logger.state.logDebug("Skipping deletion of model file still referenced by download item for configuration \(entityId.uuidString)")
				return
			}

			do {
				try fileManager.removeItem(atPath: configurationDirectory)
				Logger.state.logInfo("Model file successfully deleted for configuration \(entityId.uuidString)")
			} catch {
                let id = error.localizedDescription
				Logger.state.logError("Error deleting model file for configuration \(entityId.uuidString): \(id)")
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteModelFile", "configId": entityId.uuidString])
			}
		}
	}
}
