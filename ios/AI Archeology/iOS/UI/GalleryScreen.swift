//
//  GalleryScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct GalleryScreen: Screen {
	@ViewBuilder
	static func content() -> some View {
		ImageGalleryApp()
	}

	@ViewBuilder
	static func barItems(position: ItemsPosition) -> some View {
		switch position {
			case .leading:
				HStack {
					Button ( action:  {
							// presentSideMenu.toggle()
					}, label: { Image(systemName: "cpu").foregroundColor(.gray.opacity(0.8))})
				}
			case .trailing:
				HStack {
					Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray.opacity(0.8))})
					Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray.opacity(0.8))})
					Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray.opacity(0.8))})
				}
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
			Image(systemName:"rectangle.grid.2x2").environment(\.symbolVariants, .none)
		}
		Text("Gallery")
	}
}

	//TODO: Only for demo scene
struct ImageGalleryApp: View {
	@StateObject var dataModel = DataModel()

	var body: some View {
		GridView()
			.environmentObject(dataModel)
	}
}
