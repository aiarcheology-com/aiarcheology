//
//  AppEntry.swift
//  AI Archeology
//
//  AIA-0970, AIA-0991.
//

import SwiftUI

/// The process entry point: the app with its UI, or — in headless mode — the same app without it.
///
/// Chosen at launch by `-interface headless` (AIA-0991), and only in a Debug build against the
/// development backend: anywhere else the branch is not compiled, so a shipping build, or a Debug
/// build against production, always launches the UI. See `specification/HEADLESS.md`.
@main
enum AppEntry {
	@MainActor
	static func main() {
		#if DEBUG && AIA_BACKEND_ENV_development
		if AppEnvironment.isHeadlessMode {
			MLBrowserHeadless.main()
			return
		}
		#endif
		MLBrowser.main()
	}
}
