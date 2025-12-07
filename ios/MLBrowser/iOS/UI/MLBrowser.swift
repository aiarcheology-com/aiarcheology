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
		Logger.lifecycle.logInfo("MLBrowser app launching")
		DefaultCrashReporter.shared.recordBreadcrumb("App initialized", level: .info)
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
                Logger.lifecycle.logInfo("App entering background")
                if appState.guide.ontheflyDetectionEnabled {
                    appState.settings.isDetectionPaused = true
                    appState.guide.ontheflyDetectionTapped()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Logger.lifecycle.logInfo("App entering foreground")
                if appState.settings.isDetectionPaused {
                    appState.settings.isDetectionPaused = false
                    appState.guide.ontheflyDetectionTapped()
                }
            }
        }
    }
}
