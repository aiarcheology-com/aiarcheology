//
//  SheetDismissButtonModifier.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 05.12.24.
//

import SwiftUI

/// Adds a trailing "Dismiss" button to the navigation bar that dismisses the presenting sheet.
///
/// Usage:
/// ```swift
/// MyView()
///     .sheetDismissButton(testability: .browsingHistoryDismiss)
/// ```
struct SheetDismissButtonModifier: ViewModifier {
	@Environment(\.dismissSheet) private var dismissSheet
	let testability: Testability.Button

	func body(content: Content) -> some View {
		content
			.navigationBarItems(trailing: Button(action: {
				dismissSheet?()
			}) {
				Text(L10n.Common.dismiss)
					.bold()
					.foregroundColor(.blue)
			}
			.testability(testability)
			)
	}
}

extension View {
	func sheetDismissButton(testability: Testability.Button) -> some View {
		modifier(SheetDismissButtonModifier(testability: testability))
	}
}
