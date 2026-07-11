//
//  EnvironmentValues+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 05.12.24.
//

import SwiftUI

// MARK: - Sheet Dismiss

/// Environment key for propagating sheet-level dismiss action through navigation hierarchies.
/// Use this when a deeply nested view needs to dismiss the entire sheet, not just pop navigation.
private struct SheetDismissKey: EnvironmentKey {
	nonisolated static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
	/// Dismisses the presenting sheet from any depth in the navigation stack.
	///
	/// Inject at the sheet's root:
	/// ```swift
	/// NavigationLink(destination: ChildView())
	///     .environment(\.dismissSheet, { dismiss() })
	/// ```
	///
	/// Consume in nested views:
	/// ```swift
	/// @Environment(\.dismissSheet) var dismissSheet
	/// Button("Done") { dismissSheet?() }
	/// ```
	var dismissSheet: (@MainActor @Sendable () -> Void)? {
		get { self[SheetDismissKey.self] }
		set { self[SheetDismissKey.self] = newValue }
	}
}

// MARK: - Bottom address bar (AIA-0338)

/// Whether the address bar should render at the bottom of the screen instead of in
/// the top `.principal` toolbar slot. Computed once in `ContentView` (so the top and
/// bottom placement gates can never transiently disagree on rotation) and read by
/// `WebScreenView`. Defaults to `false` so any host that doesn't inject it (previews,
/// or a `WebScreenView` instantiated outside `ContentView`) keeps the top bar.
private struct BottomAddressBarActiveKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	/// See `BottomAddressBarActiveKey`. iPhone-portrait, normal-mode, web-tab only.
	var bottomAddressBarActive: Bool {
		get { self[BottomAddressBarActiveKey.self] }
		set { self[BottomAddressBarActiveKey.self] = newValue }
	}
}

// MARK: - Real vs. mock auth (AIA-0385)

/// Whether real Clerk-backed auth is active (vs. the DEBUG mock). Decided by the single
/// composition root (`DependencyContainer`) and injected once at the app root as
/// `AppState.usesRealAuth`, so Views read this instead of reaching into `DependencyContainer.shared`.
///
/// Defaults to `false` (the mock / no-Clerk path) so isolated SwiftUI previews and
/// unit-test-rendered views never require a configured Clerk instance — matching the value they
/// saw before (tests/previews run with `usesMockAuth == true`). Production and UI-test launches
/// always override it at the root.
///
/// NOTE: like `\.managedObjectContext`, this does NOT reliably cross `.sheet` boundaries on Mac
/// (Designed for iPad) — re-inject it on any sheet whose content reads it (e.g. `SettingsForm`).
private struct UsesRealAuthKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	/// See `UsesRealAuthKey`.
	var usesRealAuth: Bool {
		get { self[UsesRealAuthKey.self] }
		set { self[UsesRealAuthKey.self] = newValue }
	}
}
