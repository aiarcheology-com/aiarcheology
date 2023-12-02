//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI

@main
struct MLBrowser: App {
	@StateObject var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
				.environment(\.managedObjectContext, appState.dataController.container.viewContext)
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { output in
					// TODO: Possibly treat the case with the app reset. But for now the user has to reinstall the app,
					// if he wants to use e.g. the demo models.
					appState.settings.isFirstLaunch = false
				}
        }
    }
}
