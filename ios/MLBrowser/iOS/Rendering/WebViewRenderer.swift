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
    unowned var snapAdjustment: SnapAdjustment
    
    init(snapAdjustment: SnapAdjustment) {
        self.snapAdjustment = snapAdjustment
        super.init()
    }

	@MainActor override func render<Content>(_ content: Content, scale: CGFloat, completionHandler: @escaping @MainActor (UIImage?, Error?) -> Void) where Content: View {
		guard let webView = webView else {
			completionHandler(nil, nil) // TODO: error handling
			return
		}

		// Capture the adjustment values on the main actor before hopping off it.
		let brightness = snapAdjustment.brightness
		let contrast = snapAdjustment.contrast
		let saturation = snapAdjustment.saturation

		let scroll = webView.scrollView
		LoggingPolicy.debug(
			"WebViewGeometry: bounds=\(webView.bounds.size.width)x\(webView.bounds.size.height)"
			+ " originY=\(webView.convert(CGPoint.zero, to: nil).y)"
			+ " offsetY=\(scroll.contentOffset.y)"
			+ " insetTop=\(scroll.adjustedContentInset.top) insetBottom=\(scroll.adjustedContentInset.bottom)",
			logger: .ui
		)

		let config = WKSnapshotConfiguration()
		webView.takeSnapshot(with: config) { image, error in
			guard let image else {
				completionHandler(nil, error)
				return
			}
			// The takeSnapshot func does not take in account the changes in the SwiftUI
			// api (brightness, contrast, saturation) and has to be explicitly set here.
			// The Core Image render is expensive — run it off the main thread; the
			// @MainActor completion handler hops back to the main actor automatically.
			Task.detached(priority: .userInitiated) {
				let updatedImage = image.adjusted(brightness: brightness,
												  contrast: contrast,
												  saturation: saturation)
				await completionHandler(updatedImage, error)
			}
		}
	}
}
