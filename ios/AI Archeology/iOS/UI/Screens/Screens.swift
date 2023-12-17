//
//  Screens.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct Screens {
	@ViewBuilder
	static func content(_ mode: AppMode) -> some View {
		switch mode {
			case .web:
				WebScreen.content()
			case .gallery:
				GalleryScreen.content()
		}
	}

	@ViewBuilder
	static func barItems(_ mode: AppMode, position: ItemsPosition) -> some View {
		switch mode {
			case .web:
				WebScreen.barItems(position: position)
			case .gallery:
				GalleryScreen.barItems(position: position)
		}
	}

	@ViewBuilder
	static func tabItem(_ mode: AppMode, selection: AppMode) -> some View {
		switch mode {
			case .web:
				WebScreen.tabItem(selection: selection)
			case .gallery:
				GalleryScreen.tabItem(selection: selection)
		}
	}
}
