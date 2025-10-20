//
//  WebViewRenderer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import WebKit
import SwiftUI
import OSLog

protocol WebViewRenderable {
	var webViewRenderer: WebViewRenderer { get }
}

// Webview renderer for the components with a nested WebView
class WebViewRenderer: DefaultRenderer {
	var webView: WKWebView?

	@MainActor override func render<Content>(_ content: Content, completionHandler: @escaping (UIImage?, Error?) -> Void) where Content: View {
		guard let webView = webView else {
			completionHandler(nil, nil) // TODO: error handling
			return
		}

		let config = WKSnapshotConfiguration()
		webView.takeSnapshot(with: config) { [weak self] image, error in
			guard let self else {
				Logger.rendering.warning("\(Logger.timestamp)WebViewRenderer deallocated during snapshot operation")
				return
			}
			if let image = image {
					// The takeSnapshot func does not take in account the changes in the SwiftUI
					// api (brightness, contrast, saturation) and has to be explicitly set here:
				let updatedImage = image.adjusted(brightness: appState.snapAdjustment.brightness,
												  contrast: appState.snapAdjustment.contrast,
												  saturation: appState.snapAdjustment.saturation)
				completionHandler(updatedImage, error)
			} else {
				completionHandler(nil, error)
			}
		}
	}
}
