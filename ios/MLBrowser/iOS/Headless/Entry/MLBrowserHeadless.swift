//
//  MLBrowserHeadless.swift
//  AI Archeology
//
//  AIA-0970: the app without its UI.
//

#if DEBUG && AIA_BACKEND_ENV_development
import HeadlessKit
import HeadlessKitTransport
import SwiftUI

/// ML Browser without its UI, driven over a loopback socket (`specification/HEADLESS.md`).
///
/// The same process as the app: the same delegate, the same bootstrap, the same `AppRuntime`, the
/// same composition root. Only the views are replaced — by one static status line, because an iOS
/// app always has a window — and a `HeadlessServer` takes their place as the way in.
///
/// Headless mode of the Debug app, entered with `-interface headless` (AIA-0991). The whole file
/// compiles only in a Debug build against the development backend, so no other build carries a
/// command server.
struct MLBrowserHeadless: App {
	@UIApplicationDelegateAdaptor(BackgroundDownloadAppDelegate.self) var appDelegate
	@StateObject private var appState: AppState
	private let runtime: AppRuntime
	@State private var server = HeadlessServerController()

	init() {
		Self.seedFreeAccessExpiryIfRequested(container: DependencyContainer.shared)
		let appState = AppRuntime.bootstrap(container: DependencyContainer.shared)
		_appState = StateObject(wrappedValue: appState)
		runtime = AppRuntime(appState: appState)
	}

	/// `-headlessFreeAccessEndsIn` (AIA-0984). Before `bootstrap`, because `AppState`'s initializer
	/// starts the task that runs `FreeAccessState.start()`, the first read of the window.
	private static func seedFreeAccessExpiryIfRequested(container: DependencyContainer) {
		guard let seconds = HeadlessLaunchOptions.current.freeAccessEndsIn else { return }
		let result = FreeAccessExpirySeed.seedWindowEnding(
			inSeconds: seconds,
			fastStore: container.settings.persistenceStore,
			durableStore: container.freeAccessDurableStore
		)
		// An existing anchor is expected on a relaunch, which passes the option again. An unreadable
		// Keychain is not: the run would go on in a days-long window and fail minutes later at its
		// `access-ended` wait, far from the cause.
		if case .failure(.durableStoreUnreadable) = result {
			fatalError("-headlessFreeAccessEndsIn: the free-access Keychain anchor could not be read, so the window was not seeded")
		}
	}

	var body: some Scene {
		WindowGroup {
			// Not localized, deliberately: a developer-only status line in a Debug-only build, kept out
			// of the string catalog with `verbatim`.
			Text(verbatim: server.status)
				.font(.system(.footnote, design: .monospaced))
				.padding()
				.task {
					runtime.start()
					await server.start(appState: appState)
				}
		}
	}
}

/// Owns the loopback server for the life of the process.
@MainActor
@Observable
final class HeadlessServerController {

	private(set) var status = "ML Browser headless: starting"
	private var server: HeadlessServer?

	/// Where clients find the endpoint: inside the app's own data container, which the launching
	/// tool reads with `simctl get_app_container … data`.
	static var endpointFile: URL {
		URL.applicationSupportDirectory.appending(path: "Headless/endpoint.json")
	}

	func start(appState: AppState) async {
		guard server == nil else { return }
		// A lock on production data, besides the compile-time exclusion and the launching tool's:
		// a headless process never serves commands against anything but the development backend.
		guard BackendEnvironment.current == .development else {
			status = "ML Browser headless: refused — backend is \(BackendEnvironment.current.rawValue)"
			LoggingPolicy.error("Headless server refused: not on the development backend", logger: .lifecycle)
			return
		}
		// The adapters' one read of this launch's options: the application takes what it needs from
		// the parts.
		let launchOptions = HeadlessLaunchOptions.current
		let application = MLBrowserHeadlessApplication(
			parts: HeadlessAppParts(appState: appState, launchOptions: launchOptions),
			launchOptions: launchOptions.json,
			crashReporting: DependencyContainer.shared.usesRealCrashReporter
		)
		let server = HeadlessServer(session: HeadlessSession(application: application), endpointFile: Self.endpointFile)
		self.server = server
		do {
			let endpoint = try await server.start()
			status = "ML Browser headless: listening on \(endpoint.host):\(endpoint.port)"
			LoggingPolicy.info("Headless server listening on port \(endpoint.port)", logger: .lifecycle)
		} catch {
			self.server = nil
			status = "ML Browser headless: server failed to start"
			LoggingPolicy.error("Headless server failed to start", error: error, logger: .lifecycle)
		}
	}
}
#endif
