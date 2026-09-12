//
//  BrowserSession.swift
//  AI Archeology
//
//  AIA-0390: the browser feature grouped into one injectable, independently-testable session.
//  Owns the derived browser state (browser state + visit-trail recorder) and is built by
//  `DependencyContainer.makeAppState()`; `AppState` forwards `browserState`/`visitTrail` to it.
//

import Foundation

@MainActor
final class BrowserSession {
	// MARK: - Injected shared services (owned by DependencyContainer).
	//
	// INVARIANT (AIA-0390): `init` stores injected refs ONLY — never touches a `lazy var` below
	// (preserves today's first-force timing; `visitTrail` must stay unforced until AppState's
	// `initialize()` touches it to subscribe).
	private let settings: Settings
	private let dataController: DataController
	/// Forwarded to `BrowserState` so it can retry a failed load when the app becomes active
	/// (AIA-0509) without importing UIKit itself.
	private let activeNotification: Notification.Name?

	// MARK: - Owned browser feature state (lazy → forced on first access, exactly as before).
	lazy var browserState = BrowserState(settings: self.settings, activeNotification: self.activeNotification)
	lazy var visitTrail = VisitTrailRecorder(browserState: self.browserState, dataController: self.dataController)

	init(settings: Settings, dataController: DataController, activeNotification: Notification.Name? = nil) {
		self.settings = settings
		self.dataController = dataController
		self.activeNotification = activeNotification
	}
}
