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
			.onLongPressGesture(minimumDuration: 1.0) {
				// perform: fires only when the long-press completes. The previous
				// implementation copied in `pressing: false`, which fires on ANY
				// touch-up — overwriting the clipboard on a plain tap.
				UIPasteboard.general.string = copiedText
				self.showPopover = true
				DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
					self.showPopover = false
				}
			}
			.popover(isPresented: $showPopover) {
				Text(L10n.Clipboard.copied(preview))
					.padding()
			}
	}
}
