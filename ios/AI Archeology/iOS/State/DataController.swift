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
	unowned var appState: AppState
	private(set) var container: NSPersistentContainer

	init(appState: AppState) {
		self.appState = appState
		container = NSPersistentContainer(name: DataController.containerName)
		container.loadPersistentStores { description, error in
			if let error = error {
				// Core Data failure is a critical error that compromises all app functionality
				Logger.persistence.fault("Core Data failed to load persistent store: \(error.localizedDescription, privacy: .public)")
				LoggingPolicy.criticalFailure("Core Data persistent store failed to load: \(error.localizedDescription)")
			} else {
				Logger.persistence.info("Core Data persistent store loaded successfully: \(description.description, privacy: .public)")
			}
		}
	}
}
