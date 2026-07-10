//
//  DefaultRenderer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI

	// Default renderer for the SwiftUI components
class DefaultRenderer: ObservableObject {
	init() {
	}

	/// - Parameter scale: The display scale to render at. Must be read from a View's
	///   `@Environment(\.displayScale)` — declaring the property wrapper inside a function
	///   returns the default (1.0), which silently produced 1x snapshots on Retina screens.
	@MainActor func render<Content>(_ content: Content, scale: CGFloat, completionHandler: @escaping @MainActor (UIImage?, Error?) -> Void) where Content: View {
		let renderer = ImageRenderer(content: content)
		renderer.scale = scale
		renderer.isOpaque = false
		if let image = renderer.uiImage {
			completionHandler(image, nil)
		} else {
			completionHandler(nil, nil) // TODO: error handling
		}
	}
}
