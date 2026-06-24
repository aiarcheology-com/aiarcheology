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

    // MARK: - Authentication (AIA-0340)

    /// Whether the auth gate uses the in-memory mock instead of Clerk.
    /// DEBUG-only and gated on test runs, so it can never be present in
    /// Release/TestFlight builds — the auth bypass cannot ship.
    ///
    /// Covers UI tests (`UI_TESTING`), unit tests (`XCTestConfigurationFilePath`), and
    /// DEBUG builds without a valid publishable key (fresh clone with no `Secrets.xcconfig`,
    /// SwiftUI previews). All of these would otherwise take the real path and touch
    /// `Clerk.shared`, which traps (SIGILL) when Clerk was never configured. Release builds
    /// always use the real provider (the mock is `#if DEBUG`, so it can never ship).
    let usesMockAuth: Bool = {
        #if DEBUG
        return AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
            || ClerkAuthProvider.publishableKey.hasPrefix("pk_") == false
        #else
        return false
        #endif
    }()

    lazy var authProvider: AuthProviding = {
        #if DEBUG
        if self.usesMockAuth {
            return MockAuthProvider.fromLaunchArguments()
        }
        #endif
        return ClerkAuthProvider()
    }()

    // MARK: - Subscriptions (AIA-0343)

    /// Whether the subscription layer uses the in-memory mock instead of StoreKit.
    /// DEBUG-only and gated on test runs, mirroring `usesMockAuth`: UI tests and unit
    /// tests must never touch StoreKit / the App Store. Release builds always use the
    /// real provider (the mock is `#if DEBUG`, so it can never ship).
    let usesMockSubscription: Bool = {
        #if DEBUG
        return AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
        #else
        return false
        #endif
    }()

    lazy var subscriptionProvider: SubscriptionProviding = {
        #if DEBUG
        if self.usesMockSubscription {
            return MockSubscriptionProvider.fromLaunchArguments()
        }
        #endif
        return StoreKitSubscriptionProvider()
    }()

	// MARK: - Initialization
	
    private init() {
		self.crashReporter = Self.crashReporterFactory()
	}
	
	private static func crashReporterFactory() -> CrashReportingService {
		// Create crash reporter FIRST - this must happen before anything else
		let reportingRate: Float = AppEnvironment.isAppStoreDistribution ? 0.2 : 1.0
		let isTestOrDebug = AppEnvironment.isRunningUnderAnyTests || AppEnvironment.isDebugConfiguration
		
		let shouldUseRealReporter = !isTestOrDebug || AppEnvironment.requiresRealCrashReporter
		let reporter: CrashReportingService = shouldUseRealReporter
			? SentryCrashReportingService(tracesSampleRate: reportingRate)
			: NoOpCrashReportingService()

		Logger.app.info(
			"""
			
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			
				Observability initialized with reportingRate: \(reportingRate)
				isDebug: \(AppEnvironment.isDebugConfiguration)
				isTests: \(AppEnvironment.isRunningUnderAnyTests)
				requiresRealCrashReporter: \(AppEnvironment.requiresRealCrashReporter)
				usingRealReporter: \(shouldUseRealReporter)
				
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			"""
		)
		
		return reporter
	}
}
