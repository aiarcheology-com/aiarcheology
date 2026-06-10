//
//  ViewContainer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct ViewContainer<Content: View, LeadingItems: View, TrailingItems: View>: View {
	@EnvironmentObject var appState: AppState

	let barsHidden: Bool
	let content: Content
	let leadingItems: LeadingItems
	let trailingItems: TrailingItems

    @inlinable public init(barsHidden: Bool = false,
                           @ViewBuilder _ content: () -> Content,
                           @ViewBuilder leadingItems: () -> LeadingItems,
                           @ViewBuilder trailingItems: () -> TrailingItems) {
        self.barsHidden = barsHidden
        self.content = content()
        self.leadingItems = leadingItems()
        self.trailingItems = trailingItems()
    }

	var body: some View {
		NavigationStack {
			content
				.toolbar {
					ToolbarItemGroup(placement: .navigationBarLeading) {
						leadingItems
					}
					ToolbarItemGroup(placement: .navigationBarTrailing) {
						trailingItems
					}
				}
				.toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
		}
	}
}
