//
//  View+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 26.09.23.
//

import Combine
import Foundation
import SwiftUI

extension View {
	func centerInParentView() -> some View {
		VStack(alignment: .center) {
			Spacer()
			HStack(alignment: .center) {
				Spacer()
				self
				Spacer()
			}
			.frame(maxWidth: .infinity)
			Spacer()
		}
		.frame(maxWidth: .infinity)
	}
}

extension View {
	public static func removeFocus() {
#if os(iOS)
		UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#elseif os(macOS)
		DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
#endif
	}
}

extension View {
	func copiedToClipboard(copiedText: String, preview: String) -> some View {
		self.modifier(CopiedToClipboardModifier(copiedText: copiedText, preview: preview))
	}
}

/// The functions change view's properties based on the result of the isValid closure.
/// - Parameters:
/// 		- isValid: a closure that returns boolean value based on the validity of the input
/// 		- valid: a closure that modifies properties in case of isValid returns true
/// 		- invalid: a closure that modifies properties in case of isValid returns false
extension View {
	@ViewBuilder func validate<ValidView: View, InvalidView: View, T: Equatable>(
		value: T,
		isValid: @escaping (T) -> Bool,
		valid: (Self, T) -> ValidView,
		invalid: @escaping (Self, T) -> InvalidView
	) -> some View {
		if isValid(value) {
			valid(self, value)
		} else {
			invalid(self, value)
		}
	}

	@ViewBuilder func validate<InvalidView: View, T: Equatable>(
		value: T,
		isValid: @escaping (T) -> Bool,
		invalid: @escaping (Self, T) -> InvalidView
	) -> some View {
		if isValid(value).not {
			invalid(self, value)
		} else {
			self
		}
	}
}
