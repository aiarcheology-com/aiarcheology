//
//  CameraScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct CameraScreen: Screen {
	@ViewBuilder
	static func content() -> some View {
		ZStack{
			Color.black
			Image("Camera")

		}
		.foregroundColor(.black)
		.scaledToFit()
		.navigationBarTitleDisplayMode(.inline)
		.navigationTitle("Drone 02 - Online(TCP)")
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
		.camera
	}

	@ViewBuilder
	static func tabItem(selection: AppMode) -> some View {
		if tabId() == selection {
			Image(systemName: "camera.fill")
		} else {
			Image(systemName:"camera").environment(\.symbolVariants, .none)
		}
		Text("Camera")
	}
}
