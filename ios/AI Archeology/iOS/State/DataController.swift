//
//  DataController.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import CoreData

class DataController: ObservableObject {
	static let containerName = "MLBrowser"
	unowned var appState: AppState
	private(set) var container = NSPersistentContainer(name: containerName)

	init(appState: AppState) {
		self.appState = appState
		container.loadPersistentStores { description, error in
			if let error = error {
				print("Core Data failed to load: \(error.localizedDescription)")
				assert(false)
			}
		}
	}
}
