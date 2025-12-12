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
					self?.isStoreLoaded = true
				} else {
					DispatchQueue.main.async {
						self?.isStoreLoaded = true
					}
				}
			}
		}
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
