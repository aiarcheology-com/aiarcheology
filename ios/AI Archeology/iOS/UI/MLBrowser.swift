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
        }
    }
}
