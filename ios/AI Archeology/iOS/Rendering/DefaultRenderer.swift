//
//  DefaultRenderer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI

protocol DefaultRenderable {
	var defaultRenderer: DefaultRenderer { get }
}

	// Default renderer for the SwiftUI components
class DefaultRenderer: ObservableObject {
	unowned var appState: AppState

	init(appState: AppState) {
		self.appState = appState
	}

	@MainActor func render<Content>(_ content: Content, completionHandler: @escaping (UIImage?, Error?) -> Void) where Content: View {
		@Environment(\.displayScale) var displayScale
		let renderer = ImageRenderer(content: content)
		renderer.scale = displayScale
		renderer.isOpaque = false
		if let image = renderer.uiImage {
			completionHandler(image, nil)
		} else {
			completionHandler(nil, nil) //TODO: error handling
		}
	}
}
