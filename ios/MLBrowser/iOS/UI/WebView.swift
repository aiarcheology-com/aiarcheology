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
	@EnvironmentObject var browserState: BrowserState
	var request: LoadRequest
    var loadStatusChanged: ((Bool, Error?) -> Void)?
	var interactionStateChanged: ((ContentInteractionState) -> Void)?

	public init(
		_ request: LoadRequest,
		loadStatusChanged: ((Bool, Error?) -> Void)? = nil,
		interactionStateChanged: ((ContentInteractionState) -> Void)? = nil
	) {
		self.request = request
        self.loadStatusChanged = loadStatusChanged
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
		webView.allowsBackForwardNavigationGestures = true
		webView.navigationDelegate = context.coordinator
		webView.uiDelegate = context.coordinator
		webView.scrollView.delegate = context.coordinator
		webViewRenderer.webView = webView
		// The Coordinator needs BrowserState for delegate → state plumbing
		// (navigation-settled tokens, dismantle teardown).
		context.coordinator.browserState = browserState
		browserState.attach(webView)

		// No initial load here: SwiftUI guarantees updateUIView runs right after makeUIView,
		// so loading in both places fired a duplicate request (and this path bypassed the
		// withHTTPS/browserInputType normalization).
        return webView
    }

	public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
		// Subscriptions-only teardown: with the web tab being the only tab this never
		// fires today, but it must stay correct if tabOrder grows. Deliberately does NOT
		// nil webViewRenderer.webView — the snapshot ref is detection's concern and
		// clearing it on a transient rebuild would break takeSnapshot mid-detection.
		coordinator.browserState?.cancelSubscriptions(if: uiView)
	}

    public func updateUIView(
        _ uiView: WKWebView,
        context: UIViewRepresentableContext<Self>
    ) {
		// Ensure delegate stays set (can be reset by WKWebView internals)
		if uiView.scrollView.delegate == nil {
			uiView.scrollView.delegate = context.coordinator
		}

		// updateUIView also runs when unrelated SwiftUI state changes; only load when a
		// new request arrived. Dedup on generation, never on the input string — after the
		// page drifted away via the History API, re-submitting the same string must
		// perform a real load (and the navigation-settled gate relies on it).
		guard context.coordinator.lastLoadedGeneration != request.generation else { return }

        func load(_ urlString: String) {
            guard let url = URL(string: urlString.withHTTPS) else {
				// Fail open: a pending user load would otherwise strand the
				// address-display gate with no navigation to ever settle it.
				browserState.navigationIssued(nil)
				return
			}
			// Synchronous load: updateUIView already runs on the main thread, and the
			// returned navigation token keys the user-load display gate.
			let navigation = uiView.load(URLRequest(url: url))
			browserState.navigationIssued(navigation)
        }

        switch request.input.browserInputType {
        case .searchTerm:
            load(request.input.search(using: .google))
        case .url:
            load(request.input)
        case .unusable:
            return
        }
		context.coordinator.lastLoadedGeneration = request.generation
    }

    func onLoadStatusChanged(perform: ((Bool, Error?) -> Void)?) -> some View {
        var copy = self
        copy.loadStatusChanged = perform
        return copy
    }

    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        let parent: MLWebView
		var lastContentOffsetY: CGFloat = 0
		/// The generation of the last issued load; used by updateUIView to skip redundant loads.
		var lastLoadedGeneration: UInt64?
		/// Delegate → state channel for navigation tokens and dismantle teardown; weak —
		/// the state object is owned by AppState.
		weak var browserState: BrowserState?
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

		// MARK: - WKNavigationDelegate

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.loadStatusChanged?(true, nil)
			browserState?.navigationSettled(navigation, error: nil)
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.loadStatusChanged?(false, nil)

			guard let url = webView.url, let domain = url.host else {
				return
			}

			func removeJSObjects_agsCuzkCz() {
				let jsRemoveButton = "document.querySelector('.esri-component.esri-compass.esri-widget').remove();"
				webView.evaluateJavaScript(jsRemoveButton) { (_, error) in
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
		}

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loadStatusChanged?(false, error)
			browserState?.navigationSettled(navigation, error: error)
        }

		// DNS/no-network failures and a superseded load's NSURLErrorCancelled arrive
		// here, not in didFail — without this the user-load display gate would strand.
		// swiftlint:disable:next implicitly_unwrapped_optional
		public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			parent.loadStatusChanged?(false, error)
			browserState?.navigationSettled(navigation, error: error)
		}

		// MARK: - WKUIDelegate (JavaScript dialogs)

		// Without these, pages calling alert/confirm/prompt are silently suppressed.
		// UIAlertController is presented from the web view's own window, which works on
		// iOS, iPadOS, and the iPad-on-Mac build alike. Every path calls the completion
		// handler — WebKit hangs the page's JavaScript otherwise.

		public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
			guard let presenter = Self.topViewController(of: webView) else {
				completionHandler()
				return
			}
			let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { _ in
				completionHandler()
			})
			presenter.present(alert, animated: true)
		}

		public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
			guard let presenter = Self.topViewController(of: webView) else {
				completionHandler(false)
				return
			}
			let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { _ in
				completionHandler(false)
			})
			alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { _ in
				completionHandler(true)
			})
			presenter.present(alert, animated: true)
		}

		public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
			guard let presenter = Self.topViewController(of: webView) else {
				completionHandler(nil)
				return
			}
			let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
			alert.addTextField { textField in
				textField.text = defaultText
			}
			alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { _ in
				completionHandler(nil)
			})
			alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { [weak alert] _ in
				completionHandler(alert?.textFields?.first?.text)
			})
			presenter.present(alert, animated: true)
		}

		@MainActor private static func topViewController(of webView: WKWebView) -> UIViewController? {
			guard var top = webView.window?.rootViewController else { return nil }
			while let presented = top.presentedViewController {
				top = presented
			}
			return top
		}
    }

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.request == rhs.request
	}
}
