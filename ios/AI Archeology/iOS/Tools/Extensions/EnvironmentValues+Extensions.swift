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
