//
//  WebView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 22.09.23.
//
//

import Foundation
import SwiftUI
import WebKit
import Combine
import Vision
import OSLog

@available(iOS 13, *)
public struct MLWebView: UIViewRepresentable, @MainActor WebViewRenderable, @MainActor Equatable {
	@EnvironmentObject var webViewRenderer: WebViewRenderer
    var urlString: String
    var loadStatusChanged: ((Bool, Error?) -> Void)? = nil
	var lastPage: ((URL) -> Void)? = nil
	var interactionStateChanged: ((ContentInteractionState) -> Void)? = nil

	public init(_ urlString: String, lastPage: ((URL) -> Void)? = nil,
                loadStatusChanged: ((Bool, Error?) -> Void)? = nil,
				interactionStateChanged: ((ContentInteractionState) -> Void)? = nil
    ) {
        self.urlString = urlString
        self.loadStatusChanged = loadStatusChanged
		self.lastPage = lastPage
		self.interactionStateChanged = interactionStateChanged
    }

    public func makeCoordinator() -> Self.Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> WKWebView {
		// Configure user content controller for JavaScript message handling
		let contentController = WKUserContentController()
		contentController.add(context.coordinator, name: "interactionHandler")
		
		// Inject JavaScript to detect touch/pointer events
		let touchDetectionScript = WKUserScript(
			source: """
			(function() {
				let interactionTimeout = null;
				let isInteracting = false;
				
				function notifyInteractionStart() {
					if (!isInteracting) {
						isInteracting = true;
						window.webkit.messageHandlers.interactionHandler.postMessage('start');
					}
					clearTimeout(interactionTimeout);
				}
				
				function notifyInteractionEnd() {
					clearTimeout(interactionTimeout);
					interactionTimeout = setTimeout(function() {
						if (isInteracting) {
							isInteracting = false;
							window.webkit.messageHandlers.interactionHandler.postMessage('end');
						}
					}, 150);
				}
				
				// Touch events (mobile)
				document.addEventListener('touchstart', notifyInteractionStart, {passive: true, capture: true});
				document.addEventListener('touchmove', notifyInteractionStart, {passive: true, capture: true});
				document.addEventListener('touchend', notifyInteractionEnd, {passive: true, capture: true});
				document.addEventListener('touchcancel', notifyInteractionEnd, {passive: true, capture: true});
				
				// Pointer events (modern unified API)
				document.addEventListener('pointerdown', notifyInteractionStart, {passive: true, capture: true});
				document.addEventListener('pointermove', function(e) {
					if (e.pressure > 0) notifyInteractionStart();
				}, {passive: true, capture: true});
				document.addEventListener('pointerup', notifyInteractionEnd, {passive: true, capture: true});
				document.addEventListener('pointercancel', notifyInteractionEnd, {passive: true, capture: true});
				
				// Mouse events (desktop fallback)
				document.addEventListener('mousedown', notifyInteractionStart, {passive: true, capture: true});
				document.addEventListener('mousemove', function(e) {
					if (e.buttons > 0) notifyInteractionStart();
				}, {passive: true, capture: true});
				document.addEventListener('mouseup', notifyInteractionEnd, {passive: true, capture: true});
				
				// Wheel events (for zoom)
				document.addEventListener('wheel', function() {
					notifyInteractionStart();
					notifyInteractionEnd();
				}, {passive: true, capture: true});
			})();
			""",
			injectionTime: .atDocumentEnd,
			forMainFrameOnly: false
		)
		contentController.addUserScript(touchDetectionScript)
		
		let config = WKWebViewConfiguration()
		config.userContentController = contentController
		
		let webView = WKWebView(frame: .point, configuration: config)
		webView.scrollView.bounces = false
		webView.navigationDelegate = context.coordinator
		webView.scrollView.delegate = context.coordinator
		webViewRenderer.webView = webView

		if let url = URL(string: urlString) {
			DispatchQueue.main.async {
				webView.load(URLRequest(url: url))
			}
		}

        return webView
    }

    public func updateUIView(
        _ uiView: WKWebView,
        context: UIViewRepresentableContext<Self>
    ) {
		// Ensure delegate stays set (can be reset by WKWebView internals)
		if uiView.scrollView.delegate == nil {
			uiView.scrollView.delegate = context.coordinator
		}

        func load(_ urlString: String) {
            guard let url = URL(string: urlString.withHTTPS) else { return }
            DispatchQueue.main.async {
				uiView.load(URLRequest(url: url))
            }
        }

        switch urlString.browserInputType {
        case .searchTerm:
            load(urlString.search(using: .google))
        case .url:
            load(urlString)
        case .unusable:
            return
        }
    }


    func onLoadStatusChanged(perform: ((Bool, Error?) -> Void)?) -> some View {
        var copy = self
        copy.loadStatusChanged = perform
        return copy
    }

    public class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        let parent: MLWebView
		var lastContentOffsetY: CGFloat = 0
		private var isScrolling = false

        init(_ parent: MLWebView) {
            self.parent = parent
        }

		// MARK: - WKScriptMessageHandler

		public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard message.name == "interactionHandler",
				  let body = message.body as? String else { return }
			
			switch body {
			case "start":
				setScrolling(true)
			case "end":
				setScrolling(false)
			default:
				break
			}
		}

		// MARK: - UIScrollViewDelegate

		public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
			setScrolling(true)
		}

		public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
			if !decelerate {
				setScrolling(false)
			}
		}

		public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
			setScrolling(false)
		}

		public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
			setScrolling(true)
		}

		public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
			setScrolling(false)
		}

		private func setScrolling(_ value: Bool) {
			guard isScrolling != value else { return }
			isScrolling = value
			let state: ContentInteractionState = value ? .interacting : .idle
			parent.interactionStateChanged?(state)
		}

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.loadStatusChanged?(true, nil)
        }

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.loadStatusChanged?(false, nil)

			guard let url = webView.url, let domain = url.host else {
				return
			}

			func removeJSObjects_agsCuzkCz() {
				let jsRemoveButton = "document.querySelector('.esri-component.esri-compass.esri-widget').remove();"
				webView.evaluateJavaScript(jsRemoveButton) { (result, error) in
					if let error = error {
						LoggingPolicy.debug("Error removing compass button via JavaScript: \(error.localizedDescription)", logger: .ui)
					}
				}
			}
			switch domain {
			case "ags.cuzk.cz":
				removeJSObjects_agsCuzkCz()
			default:
				break
			}

			parent.lastPage?(url)
		}

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loadStatusChanged?(false, error)
        }
    }

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.urlString == rhs.urlString
	}
}
