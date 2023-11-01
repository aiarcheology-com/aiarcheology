//
//  CloudScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct CloudScreen: Screen {
	@ViewBuilder
	static func content() -> some View {
		ImageGalleryApp()
	}

	@ViewBuilder
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
			Image(systemName: "externaldrive.fill.badge.icloud")
		} else {
			Image(systemName:"externaldrive.badge.icloud").environment(\.symbolVariants, .none)
		}
		Text("Cloud")
	}
}
