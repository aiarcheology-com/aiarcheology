//
//  Appstate.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI
import Vision
import OSLog

// Responsible for keeping the data consistency across the app
// and setting up the demo structures.
@MainActor
final class AppState: ObservableObject {
	lazy var guide = Guide(
        snap: self.snap,
        deep: self.deep,
        settings: self.settings,
        dataController: self.dataController,
        demoDataManager: self.demoDataManager,
        snapAdjustment: self.snapAdjustment
    )
	lazy var snap: SnapState = DependencyContainer.shared.snapState
	lazy var renderer = DefaultRenderer()
	lazy var webViewRenderer = WebViewRenderer(snapAdjustment: self.snapAdjustment)
	lazy var browserState = BrowserState(settings: self.settings)
	lazy var visitTrail = VisitTrailRecorder(browserState: self.browserState, dataController: self.dataController)
	lazy var deep: DeepState = DependencyContainer.shared.deepState
	lazy var dataController: DataController = DependencyContainer.shared.dataController
	lazy var settings: Settings = DependencyContainer.shared.settings
	lazy var snapAdjustment = SnapAdjustment()
	lazy var downloader: Downloader = DependencyContainer.shared.downloader
    
    lazy var demoDataManager: DemoDataManager = DependencyContainer.shared.demoDataManager

	/// Interactive onboarding spotlight tour (AIA-0333). Replaces the old slideshow as the
	/// first-launch experience and is re-runnable from Settings.
	lazy var tour = TourState()

	/// Indicates whether the app initialization is complete
	@Published private(set) var isReady = false
	
	init() {
		LoggingPolicy.debug("AppState initializing", logger: .lifecycle)
		Task {
			await initialize()
		}
	}
	
	private func initialize() async {
		// 1. Wait for Core Data to be ready
		await dataController.awaitStoreReady()
		
		// 2. Create demo data if needed (checked against Core Data, not UserDefaults)
		await demoDataManager.createDemoDataIfNeeded()

		// 3. Start recording the browsing trail (lazy — must be touched to subscribe)
		_ = visitTrail

		// 4. Signal ready
		isReady = true
		LoggingPolicy.debug("AppState ready", logger: .lifecycle)
	}
}
