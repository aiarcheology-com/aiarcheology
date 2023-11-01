//
//  ViewContainer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct ViewContainer<Content: View, LeadingItems: View, TrailingItems: View>: View {
	@EnvironmentObject var appState: AppState

	let content: Content
	let leadingItems: LeadingItems
	let trailingItems: TrailingItems

	@inlinable public init(@ViewBuilder _ content: () -> Content,
						   @ViewBuilder leadingItems: () -> LeadingItems,
						   @ViewBuilder trailingItems: () -> TrailingItems) {
		self.content = content()
		self.leadingItems = leadingItems()
		self.trailingItems = trailingItems()
	}

	var body: some View {
		NavigationStack {
			ZStack {
				EmptyView()
					.navigationBarItems( leading: leadingItems)
					.navigationBarItems( trailing: trailingItems)
				content
			}
		}
	}
}
