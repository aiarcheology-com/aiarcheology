//
//  AppEntry.swift
//  AI Archeology
//
//  AIA-0970.
//

import SwiftUI

/// The process entry point: the app with its UI, or — in a headless build — the same app without it.
///
/// Chosen at build time by `AIA_APP_INTERFACE` (`ui` by default). `headless` is accepted only for a
/// Debug build against the development backend, so a shipping build always takes the first branch.
/// See `specification/HEADLESS.md`.
@main
enum AppEntry {
	@MainActor
	static func main() {
		#if DEBUG && AIA_APP_INTERFACE_headless
		MLBrowserHeadless.main()
		#else
		MLBrowser.main()
		#endif
	}
}
