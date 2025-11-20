//
//  DataController.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import CoreData
import SwiftUI
import OSLog

final class DataController: ObservableObject {
	static let containerName = "MLBrowser"
	private(set) var container: NSPersistentContainer

	init() {
		container = NSPersistentContainer(name: DataController.containerName)
        
        if let desc = container.persistentStoreDescriptions.first {
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = false
        }
        
		container.loadPersistentStores { description, error in
			if let error = error {
				// Core Data failure is a critical error that compromises all app functionality
				Logger.persistence.logFault("Core Data failed to load persistent store: \(error.localizedDescription)")
				LoggingPolicy.criticalFailure("Core Data persistent store failed to load: \(error.localizedDescription)")
			} else {
				Logger.persistence.logInfo("Core Data persistent store loaded successfully: \(description.description)")
			}
		}
	}
}
