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
	lazy var snap: any SnapStateManaging = DependencyContainer.shared.snapState
	lazy var renderer = DefaultRenderer()
	lazy var webViewRenderer = WebViewRenderer(snapAdjustment: self.snapAdjustment)
	lazy var deep: any DeepStateManaging = DependencyContainer.shared.deepState
	lazy var dataController: DataControlling = DependencyContainer.shared.dataController
	lazy var settings: any SettingsProviding = DependencyContainer.shared.settings
	lazy var snapAdjustment = SnapAdjustment()
	lazy var downloader: any Downloading = DependencyContainer.shared.downloader
    
    lazy var demoDataManager: DemoDataManaging = DependencyContainer.shared.demoDataManager
	
	init() {
		Logger.state.logInfo("AppState initializing")
		demoDataManager.createDemoEntities()
	}
	
}
