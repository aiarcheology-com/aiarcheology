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
	/// Applies the platform's native "glass" treatment in the given shape: iOS 26's Liquid Glass
	/// (`glassEffect`) where available, falling back to a translucent material with a hairline
	/// border on earlier systems. Keeps the iOS-26-only API behind one call site so feature views
	/// don't each carry the availability branch (e.g. the address field — AIA-0338).
	@ViewBuilder
	func platformEffect<S: Shape>(in shape: S = Capsule()) -> some View {
		if #available(iOS 26.0, *) {
			glassEffect(.regular, in: shape)
		} else {
			background(.ultraThinMaterial, in: shape)
				.overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
		}
	}
}

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

extension View {

	/// Gives a sheet the room its contents need where the **system**, not the screen, decides its
	/// size.
	///
	/// On iPhone a `.sheet` already fills the display and there is nothing to grow, so this is a
	/// no-op there. On iPad and on Mac (Designed for iPad) a sheet gets a form-sheet default of
	/// roughly 540×620pt, which is too small for the app's findings sheets: the save sheet alone
	/// holds a title, an address, a coordinate, a cropped preview and three more fields, and arrived
	/// with the preview squeezed to a strip (reported from a build).
	///
	/// ## `ideal`, never `min`
	/// `presentationSizing(.fitted)` sizes the SHEET from the content's ideal size, and the system
	/// then clamps that sheet to the window. Nothing clamps the *content*: a minimum wider than the
	/// window overflows and is cut off, taking the navigation bar's Cancel and Save buttons with it —
	/// in Slide Over (320pt), a one-third Split View, Stage Manager, an iPad mini in landscape, or a
	/// Mac window the user has made small. An ideal grows the sheet where there is room and yields
	/// where there is not (raised in review).
	///
	/// ## iOS 18 or nothing
	/// `presentationSizing` is iOS 18 and the app deploys to 17.6. On 17.x the sheet keeps the system
	/// size whatever the content asks for, so stating a size there could only overflow it — the
	/// earlier version did exactly that. Below 18 this does nothing at all.
	///
	/// ## Why the idiom and not the size class
	/// The obvious test is `horizontalSizeClass == .regular`, and it is wrong for exactly the case
	/// this is used in: a view **inside** a form sheet reports `.compact` on iPad, because the sheet
	/// is narrow — so the share composer, presented from inside the findings sheet, would have
	/// switched itself off and come back at the system size while its siblings grew. The idiom is a
	/// fact about the device, which nesting cannot change; it decides only whether to opt into
	/// `.fitted`, never how big the window is.
	@MainActor
	@ViewBuilder
	func roomySheet(width: CGFloat = 702, height: CGFloat = 806) -> some View {
		if SheetRoom.isGenerous, #available(iOS 18.0, *) {
			frame(idealWidth: width, idealHeight: height)
				.presentationSizing(.fitted)
		} else {
			self
		}
	}
}

/// Whether a sheet on this device is sized by the system rather than by the screen.
///
/// One place, because two things depend on the same answer: how big the sheet is made, and how its
/// contents are arranged inside it. On iPhone a sheet fills the display and both are left alone.
///
/// The **idiom**, not the size class: a view inside a form sheet reports a compact size class on
/// iPad because the sheet is narrow, so anything keyed on that would switch itself off in exactly
/// the case it is for — and a sheet presented from inside another sheet would disagree with its
/// parent about how much room the device has.
@MainActor
enum SheetRoom {

	/// True on iPad, including an iPad app running on Mac through Designed for iPad.
	///
	/// `@MainActor` because `UIDevice.current` is, and the target builds in Swift 6 language mode —
	/// today a warning, an error the moment that isolation tightens. Every caller is in a `body`.
	static var isGenerous: Bool {
		isGenerous(for: UIDevice.current.userInterfaceIdiom)
	}

	/// Keeps fitted presentation scoped to iPad, rather than treating every non-phone idiom as iPad.
	static func isGenerous(for idiom: UIUserInterfaceIdiom) -> Bool {
		idiom == .pad
	}
}
