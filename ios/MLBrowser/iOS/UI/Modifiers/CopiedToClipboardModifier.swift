//
//  CopiedToClipboardModifier.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct CopiedToClipboardModifier: ViewModifier {
	@State private var showPopover = false
	var copiedText: String
	var preview: String

	func body(content: Content) -> some View {
		content
			.onLongPressGesture(minimumDuration: 1.0, pressing: { isPressing in
				if isPressing {
						// Begin of the gesture
				} else {
						// End of the gesture
					UIPasteboard.general.string = copiedText
					self.showPopover = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
						self.showPopover = false
					}
				}
			}) {
					// This block is empty to allow the gesture to coexist with others
			}
			.popover(isPresented: $showPopover) {
				Text(L10n.Clipboard.copied(preview))
					.padding()
			}
	}
}
