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
	private let assetStore: ModelAssetStore
	private let repository: ModelConfigurationRepository

	/// Monotonic per-configuration load counter. Each `loadAndRegisterDriver` bumps it and captures
	/// the value; a completing load registers only if it is still the latest, so a load superseded by
	/// a rapid re-enable / type-switch (both start before the first `loadFile` returns) unloads its
	/// driver instead of being silently dropped by the registry's id dedup — which would leak a
	/// loaded CoreML/Vision driver (AIA-0402, codex review).
	private var driverLoadGenerations: [UUID: Int] = [:]

	init(dataController: DataController) {
		self.dataController = dataController
		self.assetStore = ModelAssetStore(dataController: dataController)
		self.repository = ModelConfigurationRepository(dataController: dataController)
		observeDeepConfigurationChanges()

		let configurations = repository.selectAll()
		let enabledConfigurationCount = configurations.filter { $0.enabled }.count
		LoggingPolicy.debug(
			"[AIA-0702 TRACE] DeepState initialized configurations=\(configurations.count) enabled=\(enabledConfigurationCount)",
			logger: .drivers
		)
		do {
			try configurations.forEach { config in
				guard config.enabled == true else { return }
				guard let driver = try self.createDriver(from: config) else { return }
				
				Task {
					do {
						try await driver.loadFile()
						// The configuration may have been deleted (e.g. reset) or disabled
						// while the model was loading.
						guard let current = selectConfiguration(config.entityId), current.enabled else {
							await driver.unload()
							return
						}
						register(driver: driver, along: config.modelType)
						LoggingPolicy.info("Driver successfully loaded and registered for configuration \(config.entityId.uuidString)", logger: .drivers)
					} catch {
						LoggingPolicy.error("Failed to load driver for configuration \(config.entityId.uuidString)", error: error, logger: .drivers)
						DefaultCrashReporter.shared.recordError(error, context: ["operation": "loadDriver", "configId": config.entityId.uuidString])
						deepStateError = error
					}
				}
			}
		} catch {
			// Send it to the upper layers to show the error to the user
			LoggingPolicy.error("Error initializing DeepState", error: error, logger: .state)
			deepStateError = error
		}
	}
	
	private func createDriver(from configuration: DeepConfiguration) throws -> (any DeepDriver)? {
		let entityId = configuration.entityId

		LoggingPolicy.debug("Creating driver of type \(configuration.modelType.rawValue) for configuration \(entityId.uuidString)", logger: .drivers)
		
		let params = configuration.toDriverParams()
		switch configuration.modelType {
		case .detector: return Detector(params: params)
		case .classificator: return Classificator(params: params)
		case .invalid:
			LoggingPolicy.error("Invalid model type for configuration \(entityId.uuidString)", logger: .drivers)
			return nil
		}
	}
	
	func cleanupTemporaryConfiguration() {
		guard let config = newConfiguration else { return }
		
		if config.shouldDeleteOnAbandon {
			// Only delete if it's still temporary (not imported/finalized)
			config.removePresentationDefaults()
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
	
	private func updaterDriver(with configuration: DeepConfiguration) async {
		await drivers.update(configuration: configuration)
	}
	
	private func unregisterDriver(driverId: UUID) {
		Task {
			await drivers.unregister(driverId: driverId)
		}
	}

	/// Builds the driver for `entityId`, loads its file, and registers it — but only if, after the
	/// async load, the configuration still exists, is still enabled, and is still the expected type.
	/// Shared by the initial-enable path and the live type-switch path (AIA-0402): a type change
	/// or a disable during the load must not register a now-stale driver.
	private func loadAndRegisterDriver(entityId: UUID, expectedType: DeepDriverType) throws {
		guard let config = selectConfiguration(entityId) else {
			LoggingPolicy.debug("[AIA-0702 TRACE] Driver load skipped: configuration no longer exists", logger: .drivers)
			LoggingPolicy.error("Could not fetch updated configuration \(entityId.uuidString)", logger: .drivers)
			return
		}

		// The config may have changed type/enabled during a preceding `await` (the unregister on a
		// type switch is a suspension point). `createDriver` builds for `config.modelType` while we
		// register `along: expectedType`, so only proceed when they still agree — otherwise a driver
		// of one type could be registered into the other type's bucket. A follow-up notification for
		// the newer state will build the right driver.
		guard config.enabled, config.modelType == expectedType else {
			LoggingPolicy.debug(
				"[AIA-0702 TRACE] Driver load skipped: enabled=\(config.enabled) expectedTypeMatches=\(config.modelType == expectedType)",
				logger: .drivers
			)
			return
		}

		LoggingPolicy.debug("[AIA-0702 TRACE] Driver load started type=\(expectedType.rawValue)", logger: .drivers)

		guard let driver = try createDriver(from: config) else {
			LoggingPolicy.error("Driver initialization failed after configuration update for config \(entityId.uuidString)", logger: .drivers)
			return
		}

		let loadGeneration = (driverLoadGenerations[entityId] ?? 0) + 1
		driverLoadGenerations[entityId] = loadGeneration

		Task {
			do {
				try await driver.loadFile()
				// The configuration may have been deleted (e.g. reset), disabled, or had its type
				// changed again while the model was loading — and a newer load for this entity may
				// have started (rapid re-enable / type-switch). Re-check all of that before
				// registering; a superseded load unloads its driver so it can't leak past the dedup.
				guard driverLoadGenerations[entityId] == loadGeneration,
					  let current = selectConfiguration(entityId), current.enabled, current.modelType == expectedType else {
					LoggingPolicy.debug("[AIA-0702 TRACE] Driver load completed stale; unloading before registration", logger: .drivers)
					await driver.unload()
					return
				}
				self.register(driver: driver, along: expectedType)
				LoggingPolicy.debug("[AIA-0702 TRACE] Driver registered type=\(expectedType.rawValue) detectors=\(drivers.detectors.count)", logger: .drivers)
				LoggingPolicy.info("Driver loaded and registered after configuration update", logger: .drivers)
			} catch {
				LoggingPolicy.error("Failed to load driver after configuration update", error: error, logger: .drivers)
				DefaultCrashReporter.shared.recordError(error, context: ["operation": "updateDriver", "configId": entityId.uuidString])
				self.deepStateError = error
			}
		}
	}
	
	func createConfiguration() -> DeepConfiguration {
		repository.create()
	}

	func updateConfiguration(
		_ entityId: UUID,
		updateClosure: @Sendable @escaping (DeepConfiguration) -> Void
	) {
		do {
			try repository.update(entityId, with: updateClosure)
		} catch {
			// Surface to the UI; a failed save would otherwise silently block all future saves.
			deepStateError = error
		}
	}

	func deleteConfiguration(_ entityId: UUID) {
		repository.delete(entityId)
	}

	func deleteConfiguration(_ entity: DeepConfiguration) {
		repository.delete(entity)
	}

	func reset() async {
		do {
			try await repository.reset()
		} catch {
			// Rows may still exist; keep drivers registered so state stays consistent.
			deepStateError = error
			return
		}

		// Batch deletes emit no NSManagedObjectContextObjectsDidChange notification,
		// so handleDeletedConfigurations never fires — unregister drivers explicitly.
		await drivers.unregisterAll()
	}

	func selectConfiguration(_ entityId: UUID) -> DeepConfiguration? {
		repository.select(entityId)
	}

	func saveConfigurations() {
		do {
			try repository.save()
		} catch {
			// Surface to the UI; a failed save would otherwise silently block all future saves.
			deepStateError = error
		}
	}

	func allConfigurations() -> [DeepConfiguration] {
		repository.selectAll()
	}
	
	// Handlers:
	private var context: NSManagedObjectContext {
		dataController.container.viewContext
	}

	private struct UpdatedConfiguration {
		let entityId: UUID
		let enabled: Bool
		let modelType: DeepDriverType
		let computeUnitChanged: Bool
	}

	private var deepConfigurationsChanges: AnyCancellable?
	
	private func observeDeepConfigurationChanges() {
		let observedContext = context
		LoggingPolicy.debug("[AIA-0702 TRACE] DeepConfiguration observer bound to current persistent context", logger: .drivers)
		deepConfigurationsChanges = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: observedContext)
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
				
				let updatedConfigs: [UpdatedConfiguration] = {
					guard let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> else { return [] }
					return updated.compactMap { obj in
						guard let config = obj as? DeepConfiguration else { return nil }
						return UpdatedConfiguration(
							entityId: config.entityId,
							enabled: config.enabled,
							modelType: config.modelType,
							computeUnitChanged: config.changedValues().keys.contains("computeUnitString")
						)
					}
				}()
				
				let deletedConfigs: [(objectID: NSManagedObjectID, entityId: UUID, demo: Bool)] = {
					guard let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return [] }
					return deleted.compactMap { obj in
						guard let config = obj as? DeepConfiguration else { return nil }
						// Use primitiveValue to safely access properties on deleted objects.
						// Direct property access can crash when bridging nil NSUUID to non-optional UUID.
						guard let entityId = config.primitiveValue(forKey: "entityId") as? UUID else { return nil }
						let demo = (config.primitiveValue(forKey: "demo") as? Bool) ?? false
						return (config.objectID, entityId, demo)
					}
				}()

				if insertedConfigs.isEmpty.not || updatedConfigs.isEmpty.not || deletedConfigs.isEmpty.not {
					LoggingPolicy.debug(
						"[AIA-0702 TRACE] DeepConfiguration context change inserted=\(insertedConfigs.count) updated=\(updatedConfigs.count) deleted=\(deletedConfigs.count)",
						logger: .drivers
					)
				}
				
				// NOW cross the async boundary with extracted data
				Task { @MainActor in
					self.handleInsertedConfigurations(insertedConfigs)
					await self.handleUpdatedConfigurations(updatedConfigs)
					await self.handleDeletedConfigurations(deletedConfigs)
				}
			}
	}
	
	private func handleInsertedConfigurations(_ inserted: [(objectID: NSManagedObjectID, entityId: UUID, enabled: Bool, modelType: DeepDriverType)]) {
		for (_, entityId, enabled, modelType) in inserted {
			LoggingPolicy.debug("[AIA-0702 TRACE] Configuration inserted enabled=\(enabled) type=\(modelType.rawValue)", logger: .drivers)
			do {
				if enabled {
					guard let config = selectConfiguration(entityId) else {
						LoggingPolicy.error("Could not fetch inserted configuration \(entityId.uuidString)", logger: .drivers)
						continue
					}
					
					guard let driver = try createDriver(from: config) else {
						LoggingPolicy.error("Driver initialization failed after configuration insert for config \(entityId.uuidString)", logger: .drivers)
						continue
					}
					
					let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
						return $0.id == entityId
					}
					
					if isDriverForThisConfigurationLoaded {
						LoggingPolicy.warning("Attempting to insert configuration with UUID that already exists: \(entityId.uuidString)", logger: .drivers)
					}
					
					Task {
						do {
							try await driver.loadFile()
							await MainActor.run {
								// The configuration may have been deleted (e.g. reset) or
								// disabled while the model was loading.
								guard let current = selectConfiguration(entityId), current.enabled else {
									Task { await driver.unload() }
									return
								}
								register(driver: driver, along: modelType)
								LoggingPolicy.info("Driver loaded and registered after configuration insert", logger: .drivers)
							}
						} catch {
							await MainActor.run {
								LoggingPolicy.error("Failed to load driver after configuration insert", error: error, logger: .drivers)
								DefaultCrashReporter.shared.recordError(error, context: ["operation": "insertDriver", "configId": entityId.uuidString])
								deepStateError = error
							}
						}
					}
				}
			} catch {
				LoggingPolicy.error("Error handling configuration insert", error: error, logger: .state)
				deepStateError = error
			}
		}
	}
	
	private func handleUpdatedConfigurations(_ updated: [UpdatedConfiguration]) async {
		for update in updated {
			let entityId = update.entityId
			let enabled = update.enabled
			let modelType = update.modelType
			let computeUnitChanged = update.computeUnitChanged
			do {
				// Which bucket, if any, currently holds this configuration's driver. A live type
				// change moves it between buckets (or out of both), which the params-only update
				// path cannot do — so we key off the loaded bucket's type, not just "is it loaded".
				let loadedType: DeepDriverType? =
					drivers.detectors.contains(where: { $0.id == entityId }) ? .detector :
					drivers.classificators.contains(where: { $0.id == entityId }) ? .classificator : nil
				LoggingPolicy.debug(
					"[AIA-0702 TRACE] Configuration update enabled=\(enabled) type=\(modelType.rawValue) loadedType=\(loadedType?.rawValue ?? "none") computeUnitChanged=\(computeUnitChanged)",
					logger: .drivers
				)

				if loadedType == nil {
					// No driver loaded yet: build one only if the model is enabled AND has a runnable
					// type. A Disabled (`.invalid`) model can't build a driver (`createDriver` returns
					// nil and logs), so skip it here — mirroring the guard in the type-change branch.
					if enabled, modelType != .invalid {
						try loadAndRegisterDriver(entityId: entityId, expectedType: modelType)
					}
				} else if loadedType != modelType {
					// Type changed on an already-loaded driver (AIA-0402). `updaterDriver` only
					// pushes params and never swaps the driver, so tear the old one down and rebuild
					// as the new type. Covers detect↔classify and any→Disabled (`.invalid` doesn't
					// rebuild, so the model stops running).
					await drivers.unregister(driverId: entityId)
					if enabled, modelType != .invalid {
						try loadAndRegisterDriver(entityId: entityId, expectedType: modelType)
					}
				} else if computeUnitChanged {
					// Compute units are fixed when Core ML creates the model. Updating params alone
					// cannot change a live Vision request, so reload the same driver type.
					await drivers.unregister(driverId: entityId)
					if enabled, modelType != .invalid {
						try loadAndRegisterDriver(entityId: entityId, expectedType: modelType)
					}
				} else {
					// Same type: a plain field change (color / threshold) or an enable toggle.
					if enabled {
						guard let config = selectConfiguration(entityId) else { continue }
						await updaterDriver(with: config)
					} else {
						unregisterDriver(driverId: entityId)
					}
				}
			} catch {
				LoggingPolicy.error("Error handling configuration update", error: error, logger: .state)
				deepStateError = error
			}
		}
	}
	
	private func handleDeletedConfigurations(_ deleted: [(objectID: NSManagedObjectID, entityId: UUID, demo: Bool)]) async {
		for (_, entityId, demo) in deleted {
			// Unregister the driver for every deleted config (incl. demo), then hand the on-disk
			// asset + DownloadItem cleanup to the asset store. Per-item catch: a cleanup failure
			// on one config must not stop the rest (matches the old per-iteration isolation).
			unregisterDriver(driverId: entityId)

			do {
				try await assetStore.cleanup(entityId: entityId, demo: demo)
			} catch {
				deepStateError = error
			}
		}
	}
}
