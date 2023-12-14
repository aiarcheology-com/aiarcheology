//
//  SideMenu.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct SideMenu<Content: View>: View {
	@Binding var presentedSideMenu: Bool

	let content: Content
	var edgeTransition: AnyTransition = .move(edge: .leading)
	var body: some View {
		ZStack(alignment: .bottom) {
			if (presentedSideMenu) {
				Color.black
					.opacity(0.3)
					.ignoresSafeArea()
				content
					.transition(edgeTransition)
					.background(
						Color.clear
					)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.ignoresSafeArea()
		.animation(.easeInOut, value: presentedSideMenu)
	}

	@inlinable public init(presentedSideMenu: Binding<Bool>, @ViewBuilder _ content: () -> Content) {
		self.content = content()
		self._presentedSideMenu = presentedSideMenu
	}
}
