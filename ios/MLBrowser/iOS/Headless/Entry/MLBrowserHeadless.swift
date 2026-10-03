//
//  MLBrowserHeadless.swift
//  AI Archeology
//
//  AIA-0970, AIA-1007: the app without its UI.
//

#if DEBUG && AIA_BACKEND_ENV_development
import HeadlessKit
import HeadlessKitUI
import SwiftUI

/// ML Browser without its UI, driven over a loopback socket (`specification/HEADLESS.md`).
///
/// The same process as the app: the same delegate, the same bootstrap, the same `AppRuntime`, the
/// same composition root. Only the views are replaced, by HeadlessKitUI's status line and the
/// server it owns. Entered with `-interface headless` (AIA-0991); the whole file compiles only in
/// a Debug build against the development backend, so no other build carries a command server.
struct MLBrowserHeadless: App {
	@UIApplicationDelegateAdaptor(BackgroundDownloadAppDelegate.self) var appDelegate
	@StateObject private var appState: AppState
	private let runtime: AppRuntime

	init() {
		// The seed writes this install's free-access anchor: only a development backend's install is
		// seeded. This file compiles only for the development backend, so today the check always
		// holds; it keeps the seed tied to the backend if that ever changes, like the server's lock
		// below. `bootstrap` still runs for any backend.
		if BackendEnvironment.current == .development {
			HeadlessLaunchOptions.current.seedFreeAccessExpiry(container: DependencyContainer.shared)
		}
		let appState = AppRuntime.bootstrap(container: DependencyContainer.shared)
		_appState = StateObject(wrappedValue: appState)
		runtime = AppRuntime(appState: appState)
	}

	var body: some Scene {
		WindowGroup {
			HeadlessServerView(onStatus: Self.log) { [appState, runtime] in
				// A lock on production data, besides the compile-time exclusion and the launching
				// tool's: a headless process never starts the runtime, or serves commands, against any
				// other backend.
				guard BackendEnvironment.current == .development else {
					throw HeadlessRefusal("backend is \(BackendEnvironment.current.rawValue)")
				}
				runtime.start()
				return MLBrowserHeadlessApplication(appState: appState)
			}
		}
	}

	private static func log(_ status: HeadlessStatus) {
		switch status {
		case .starting, .listening: LoggingPolicy.info("\(status)", logger: .lifecycle)
		case .refused, .failed: LoggingPolicy.error("\(status)", logger: .lifecycle)
		}
	}
}
#endif
