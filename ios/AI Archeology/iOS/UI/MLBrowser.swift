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
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { output in
					if appState.guide.ontheflyDetectionEnabled {
						appState.settings.isDetectionPaused = true
						appState.guide.ontheflyDetectionTapped()
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { output in
					if appState.settings.isDetectionPaused {
						appState.settings.isDetectionPaused = false
						appState.guide.ontheflyDetectionTapped()
					}
				}
        }
    }
}
