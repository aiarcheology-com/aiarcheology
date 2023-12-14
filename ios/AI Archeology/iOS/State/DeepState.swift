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

	// Drivers and DeepConfigurations have 1:1 relationship, and also
	// both entities have the same UUID. DeepConfiguations are kept in CoreData.
	// Drivers are loaded on-demand in memory and un/registered with toggling the DeepConfiguration.enabled property.
class DeepState: ObservableObject {
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
				self.register(driver: driver, along: config.modelTypeInternal)
			}
		}
		catch {
				// Send it to the upper layers to show the error to the user
			deepStateError = error
		}
	}

	private func createDriver(from configuration: DeepConfiguration) throws -> (any DeepDriver)? {
		guard let entityId = configuration.entityId else {
			assert(false, "The entityId of the configuration should be already initialised.")
			return nil
		}
		switch configuration.modelTypeInternal {
			case .detector: return try Detector(configuration: configuration, entityId: entityId)
			case .classificator: return try Classificator(configuration: configuration, entityId: entityId)
		}
	}

		// Actions:
	private func register(driver: any DeepDriver, along: DeepDriverType) {
		drivers.register(driver: driver, along: along)
	}

	private func updaterDriver(with configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else { return }
		drivers.update(driverId: entityId, configuration: configuration)
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
						assert(false, "Driver has not been initialised after a configuratoin insert.")
						return
					}

					let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
						$0.id() == config.entityId
					}

					assert(isDriverForThisConfigurationLoaded.not, "You are trying to insert a configuration with an UUID that already exist." )

					register(driver: driver, along: config.modelTypeInternal)
				}
			}
			catch {
				deepStateError = error
			}
				//else: The configuration is going to be updated yet.
		}

		let updatedObjects = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in updatedObjects.compactMap({ $0 as? DeepConfiguration }) {
			do {
				guard config.entityId.isNotNil else {
					assert(false, "The confuration should have a valid id already.")
					continue
				}
				let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
					$0.id() == config.entityId
				}
				if isDriverForThisConfigurationLoaded.not, config.enabled {
					guard let driver = try createDriver(from: config) else {
						assert(false, "Driver has not been initialised after a configuratoin insert.")
						return
					}
					register(driver: driver, along: config.modelTypeInternal)
				} else {
					if config.enabled {
						updaterDriver(with: config)
					} else {
						unregisterDriver(with: config)
					}

				}
			}
			catch {
				deepStateError = error
			}
		}

		let deletedObjects = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in deletedObjects.compactMap({ $0 as? DeepConfiguration }) {
			unregisterDriver(with: config)

				// Delete the model file:
			let fileManager = FileManager.default
			guard let configurationId = config.entityId?.uuidString else {
				print("Can not reconstruct the path to the configuration's directory.")
				return

			}

			let documentDirectory = FileManager.default.documentDirectory
			guard
				let configurationDirectory = documentDirectory?
					.appendingPathComponent("Configurations")
					.appendingPathComponent(configurationId)
					.path(percentEncoded: false),
				fileManager.fileExists(atPath: configurationDirectory)
			else {
				print("There is no filepath, or the file does not exist.")
				return
			}

			guard config.demo.not else {
					// DO NOT DELETE THE MODEL that is part of the demo
				return
			}
			do {
				try fileManager.removeItem(atPath: configurationDirectory)
				print("File successfully deleted")
			} catch {
				assert(false, "Error deleting file: \(error.localizedDescription)")
			}
		}
	}
}
