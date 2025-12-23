//
//  DependencyContainer.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import Combine
import OSLog

@MainActor
class DependencyContainer {
	static let shared = DependencyContainer()
	
	// MARK: - Crash Reporting (Eager Initialization)
	
	/// The crash reporting service. Initialized eagerly to ensure Observability
	/// is started before any code can call DefaultCrashReporter.shared.
	let crashReporter: CrashReportingService
	
	// MARK: - Lazy Dependencies
    
    lazy var dataController: DataController = {
        return DataController()
    }()
    
    lazy var settings: Settings = {
        return Settings()
    }()
    
    lazy var snapState: SnapState = {
        return SnapState(settings: self.settings)
    }()
    
    lazy var deepState: DeepState = {
        return DeepState(dataController: self.dataController)
    }()
    
    lazy var downloader: Downloader = {
        return Downloader(dataController: self.dataController)
    }()
    
    lazy var demoDataManager: DemoDataManager = {
        return DemoDataManager(dataController: self.dataController)
    }()
    
	// MARK: - Initialization
	
    private init() {
		self.crashReporter = Self.crashReporterFactory()
	}
	
	private static func crashReporterFactory() -> CrashReportingService {
		// Create crash reporter FIRST - this must happen before anything else
		let reportingRate: Float = 0.5
		let isThrottlingTestMode = AppEnvironment.sentryThrottleSmokeTestMode?.isEmpty == false
		let reporter: CrashReportingService = (AppEnvironment.isRunningUnderAnyTests || AppEnvironment.isDebugConfiguration) && isThrottlingTestMode.not
			? NoOpCrashReportingService()
			: SentryCrashReportingService(tracesSampleRate: reportingRate)

		Logger.app.info(
			"""
			
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			
				Observability initialized with reportingRate: \(reportingRate)
				isDebug: \(AppEnvironment.isDebugConfiguration)
				isTests: \(AppEnvironment.isRunningUnderAnyTests)
				
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			"""
		)
		
		return reporter
	}
}

