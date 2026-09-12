//
//  GalleryScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct GalleryScreen: @MainActor Screen {
	@ViewBuilder
	static func content() -> some View {
		ImageGalleryApp()
	}

    @MainActor @ViewBuilder
	static func barItems(position: ItemsPosition) -> some View {
		switch position {
		case .leading:
			GlobalToolbarLeading()
		case .trailing:
			GlobalToolbarTrailing()
		}
	}

	static func tabId() -> AppMode {
		.gallery
	}

	@ViewBuilder
	static func tabItem(selection: AppMode) -> some View {
		if tabId() == selection {
			Image(systemName: "rectangle.grid.2x2.fill")
		} else {
			Image(systemName: "rectangle.grid.2x2").environment(\.symbolVariants, .none)
		}
		Text(L10n.Tab.examples)
	}
}

	// TODO: Only for demo scene
struct ImageGalleryApp: View {
	@StateObject var dataModel = DataModel()

	var body: some View {
		GridView()
			.environmentObject(dataModel)
	}
}
