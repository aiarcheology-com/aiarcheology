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
@MainActor
final class DeepState: ObservableObject {
	let dataController: DataController
	
	@Published var newConfiguration: DeepConfiguration?
	@Published var deepStateError: Error?
    var deepStateErrorPublisher: Published<Error?>.Publisher { $deepStateError }
	var drivers = DeepDrivers()
	
	init(dataController: DataController) {
		self.dataController = dataController
		observeDeepConfigurationChanges()
		
		let configurations = DeepConfiguration.selectAll(in: dataController.container.viewContext)
		do {
			try configurations.forEach { config in
				guard config.enabled == true else { return }
				guard let driver = try self.createDriver(from: config) else { return }
				
				Task {
					do {
						try await driver.loadFile()
						register(driver: driver, along: config.modelType)
						Logger.drivers.logInfo("Driver successfully loaded and registered for configuration \(config.entityId.uuidString)")
					}
					catch {
						Logger.drivers.logError("Failed to load driver for configuration \(config.entityId.uuidString): \(error.localizedDescription)")
						DefaultCrashReporter.shared.recordError(error, context: ["operation": "loadDriver", "configId": config.entityId.uuidString])
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
		let entityId = configuration.entityId
		
		Logger.drivers.logDebug("Creating driver of type \(configuration.modelType.rawValue) for configuration \(entityId.uuidString)")
		
		let params = configuration.toDriverParams()
		switch configuration.modelType {
		case .detector: return Detector(params: params)
		case .classificator: return Classificator(params: params)
		case .invalid:
			Logger.drivers.logError("Invalid model type for configuration \(entityId.uuidString)")
			return nil
		}
	}
	
	func cleanupTemporaryConfiguration() {
		guard let config = newConfiguration else { return }
		
		if config.shouldDeleteOnAbandon {
			// Only delete if it's still temporary (not imported/finalized)
			DeepConfiguration.delete(config, in: context)
		}
		
		newConfiguration = nil
	}
	
	func createTemportaryConfiguration() {
		self.newConfiguration = self.createConfiguration()
	}
	
	// Actions:
	private func register(driver: any DeepDriver, along: DeepDriverType) {
		drivers.register(driver: driver, along: along)
	}
	
	private func updaterDriver(with configuration: DeepConfiguration) {
		drivers.update(configuration: configuration)
	}
	
	private func unregisterDriver(driverId: UUID) {
		Task {
			await drivers.unregister(driverId: driverId)
		}
	}
	
	func createConfiguration() -> DeepConfiguration {
		let context = dataController.container.viewContext
		return DeepConfiguration.create(in: context)
	}
	
	func updateConfiguration(
		_ entityId: UUID,
		updateClosure: @Sendable @escaping (DeepConfiguration) -> Void
	) {
		let context = dataController.container.viewContext
		DeepConfiguration.update(entityId, in: context, with: updateClosure)
	}
	
	func deleteConfiguration(_ entityId: UUID) {
		let context = dataController.container.viewContext
		DeepConfiguration.delete(entityId, in: context)
	}
	
	func deleteConfiguration(_ entity: DeepConfiguration) {
		let context = dataController.container.viewContext
		DeepConfiguration.delete(entity, in: context)
	}
	
	func reset() {
		let context = dataController.container.viewContext
		DeepConfiguration.deleteAll(in: context)
	}
	
	func selectConfiguration(_ entityId: UUID) -> DeepConfiguration? {
		let context = dataController.container.viewContext
		return DeepConfiguration.select(entityId, in: context)
	}
	
	func saveConfigurations() {
		let context = dataController.container.viewContext
		return DeepConfiguration.save(in: context)
	}
	
	func allConfigurations() -> [DeepConfiguration] {
		let context = dataController.container.viewContext
		return DeepConfiguration.selectAll(in: context)
	}
	
	// Handlers:
	private var context: NSManagedObjectContext {
		dataController.container.viewContext
	}
	private var deepConfigurationsChanges: AnyCancellable?
	
	private func observeDeepConfigurationChanges() {
		deepConfigurationsChanges = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
			.sink { [weak self] notification in
				guard let self = self else { return }
				
				// Extract all needed data IMMEDIATELY while objects are still valid
				let insertedConfigs: [(objectID: NSManagedObjectID, entityId: UUID, enabled: Bool, modelType: DeepDriverType)] = {
					guard let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> else { return [] }
					return inserted.compactMap { obj in
						guard let config = obj as? DeepConfiguration else { return nil }
						return (config.objectID, config.entityId, config.enabled, config.modelType)
					}
				}()
				
				let updatedConfigs: [(objectID: NSManagedObjectID, entityId: UUID, enabled: Bool, modelType: DeepDriverType)] = {
					guard let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> else { return [] }
					return updated.compactMap { obj in
						guard let config = obj as? DeepConfiguration else { return nil }
						return (config.objectID, config.entityId, config.enabled, config.modelType)
					}
				}()
				
				let deletedConfigs: [(objectID: NSManagedObjectID, entityId: UUID, demo: Bool)] = {
					guard let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
					return deleted.compactMap { obj in
						guard let config = obj as? DeepConfiguration else { return nil }
						return (config.objectID, config.entityId, config.demo)
					}
				}()
				
				// NOW cross the async boundary with extracted data
				Task { @MainActor in
					self.handleInsertedConfigurations(insertedConfigs)
					await self.handleUpdatedConfigurations(updatedConfigs)
					self.handleDeletedConfigurations(deletedConfigs)
				}
			}
	}
	
	private func handleInsertedConfigurations(_ inserted: [(objectID: NSManagedObjectID, entityId: UUID, enabled: Bool, modelType: DeepDriverType)]) {
		for (_, entityId, enabled, modelType) in inserted {
			do {
				if enabled {
					guard let config = selectConfiguration(entityId) else {
						Logger.drivers.logError("Could not fetch inserted configuration \(entityId.uuidString)")
						continue
					}
					
					guard let driver = try createDriver(from: config) else {
						Logger.drivers.logError("Driver initialization failed after configuration insert for config \(entityId.uuidString)")
						continue
					}
					
					let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
						return $0.id == entityId
					}
					
					if isDriverForThisConfigurationLoaded {
						Logger.drivers.logWarning("Attempting to insert configuration with UUID that already exists: \(entityId.uuidString)")
					}
					
					Task {
						do {
							try await driver.loadFile()
							await MainActor.run {
								register(driver: driver, along: modelType)
								Logger.drivers.logInfo("Driver loaded and registered after configuration insert")
							}
						}
						catch {
							await MainActor.run {
								Logger.drivers.logError("Failed to load driver after configuration insert: \(error.localizedDescription)")
								DefaultCrashReporter.shared.recordError(error, context: ["operation": "insertDriver", "configId": entityId.uuidString])
								deepStateError = error
							}
						}
					}
				}
			}
			catch {
				Logger.state.logError("Error handling configuration insert: \(error.localizedDescription)")
				deepStateError = error
			}
		}
	}
	
	private func handleUpdatedConfigurations(_ updated: [(objectID: NSManagedObjectID, entityId: UUID, enabled: Bool, modelType: DeepDriverType)]) async {
		for (_, entityId, enabled, modelType) in updated {
			do {
				let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
					return $0.id == entityId
				}
				
				if isDriverForThisConfigurationLoaded.not, enabled {
					guard let config = selectConfiguration(entityId) else {
						Logger.drivers.logError("Could not fetch updated configuration \(entityId.uuidString)")
						continue
					}
					
					guard let driver = try createDriver(from: config) else {
						Logger.drivers.logError("Driver initialization failed after configuration update for config \(entityId.uuidString)")
						continue
					}
					
					Task {
						do {
							try await driver.loadFile()
							self.register(driver: driver, along: modelType)
							Logger.drivers.logInfo("Driver loaded and registered after configuration update")
						} catch {
							Logger.drivers.logError("Failed to load driver after configuration update: \(error.localizedDescription)")
							DefaultCrashReporter.shared.recordError(error, context: ["operation": "updateDriver", "configId": entityId.uuidString])
							self.deepStateError = error
						}
					}
				} else {
					if enabled {
						guard let config = selectConfiguration(entityId) else { continue }
						updaterDriver(with: config)
					} else {
						unregisterDriver(driverId: entityId)
					}
				}
			}
			catch {
				Logger.state.logError("Error handling configuration update: \(error.localizedDescription)")
				deepStateError = error
			}
		}
	}
	
	private func handleDeletedConfigurations(_ deleted: [(objectID: NSManagedObjectID, entityId: UUID, demo: Bool)]) {
		for (_, entityId, demo) in deleted {
			unregisterDriver(driverId: entityId)
			
			let fileManager = FileManager.default
			
			guard
				let configurationDirectory = FileManager.deepConfigurationDirectory(id: entityId)?.path(percentEncoded: false),
				fileManager.fileExists(atPath: configurationDirectory)
			else {
				Logger.state.logDebug("Configuration directory does not exist or path is nil for \(entityId.uuidString)")
				continue
			}
			
			guard demo.not else {
				Logger.state.logDebug("Skipping deletion of demo model for configuration \(entityId.uuidString)")
				continue
			}
			
			guard DownloadItem.select(entityId, in: dataController.container.viewContext).isNil else {
				Logger.state.logDebug("Skipping deletion of model file still referenced by download item for configuration \(entityId.uuidString)")
				continue
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
