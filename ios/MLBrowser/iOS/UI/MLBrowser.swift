//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import OSLog

@main
struct MLBrowser: App {
	@StateObject var appState = AppState()
	
	init() {
		Observability.start(with: DependencyContainer.shared.crashReporter)
		Observability.runTestTriggersIfEnabled()
		LoggingPolicy.info("MLBrowser app launching", logger: .lifecycle)
	}
	
	var body: some Scene {
		WindowGroup {
			Group {
				if appState.isReady {
					ContentView()
						.environmentObject(appState)
						.environment(\.managedObjectContext, appState.dataController.container.viewContext)
				} else {
					ProgressView("Loading...")
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				LoggingPolicy.info("App entering background", logger: .lifecycle)
				if appState.guide.ontheflyDetectionEnabled {
					appState.settings.isDetectionPaused = true
					appState.guide.ontheflyDetectionTapped()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				LoggingPolicy.info("App entering foreground", logger: .lifecycle)
				if appState.settings.isDetectionPaused {
					appState.settings.isDetectionPaused = false
					appState.guide.ontheflyDetectionTapped()
				}
			}
		}
	}
}
