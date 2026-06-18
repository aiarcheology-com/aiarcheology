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
	/// When true, the content extends edge-to-edge under the device safe-area insets.
	/// Used for fullscreen detection on iPhone, where reserving the safe area left
	/// unused blank margins around the map (AIA-0336). `edges: []` is a no-op, so the
	/// safe area is honored as usual when false.
	let contentIgnoresSafeArea: Bool
	let content: Content
	let leadingItems: LeadingItems
	let trailingItems: TrailingItems

    @inlinable public init(barsHidden: Bool = false,
                           contentIgnoresSafeArea: Bool = false,
                           @ViewBuilder _ content: () -> Content,
                           @ViewBuilder leadingItems: () -> LeadingItems,
                           @ViewBuilder trailingItems: () -> TrailingItems) {
        self.barsHidden = barsHidden
        self.contentIgnoresSafeArea = contentIgnoresSafeArea
        self.content = content()
        self.leadingItems = leadingItems()
        self.trailingItems = trailingItems()
    }

	var body: some View {
		NavigationStack {
			content
				.ignoresSafeArea(.container, edges: contentIgnoresSafeArea ? .all : [])
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
