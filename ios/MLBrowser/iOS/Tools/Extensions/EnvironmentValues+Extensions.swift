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
