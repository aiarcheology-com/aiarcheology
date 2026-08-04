//
//  WebView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 22.09.23.
//
//

import Foundation
import SwiftUI
import UIKit
import WebKit
import Combine
import Vision
import OSLog

@available(iOS 13, *)
public struct MLWebView: UIViewRepresentable, @MainActor Equatable {
	let renderer: WebSnapshotRenderer
	@EnvironmentObject var browserState: BrowserState
	var request: LoadRequest
    var loadStatusChanged: ((Bool, Error?) -> Void)?
	var interactionStateChanged: ((ContentInteractionState) -> Void)?

	init(
		_ request: LoadRequest,
		renderer: WebSnapshotRenderer,
		loadStatusChanged: ((Bool, Error?) -> Void)? = nil,
		interactionStateChanged: ((ContentInteractionState) -> Void)? = nil
	) {
		self.request = request
		self.renderer = renderer
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
		// Let the page fill the web view's frame edge-to-edge instead of insetting its
		// content by the safe area. In normal mode SwiftUI already bounds the frame to the
		// safe area, so this is a no-op there; in fullscreen detection the frame is full-bleed
		// (safe area ignored), and without this the scroll view would re-inset the page,
		// leaving the blank margins AIA-0336 set out to remove.
		webView.scrollView.contentInsetAdjustmentBehavior = .never
		webView.allowsBackForwardNavigationGestures = true
		webView.navigationDelegate = context.coordinator
		webView.uiDelegate = context.coordinator
		webView.scrollView.delegate = context.coordinator
		renderer.attach(webView)
		// The Coordinator needs BrowserState for delegate → state plumbing
		// (navigation-settled tokens, dismantle teardown).
		context.coordinator.browserState = browserState
		browserState.attach(webView)

		// AIA-0509: restore the back-forward stack after a recovery rebuild. Deliberately last —
		// after `navigationDelegate` is assigned above, so the restore navigation is observed, and
		// after `browserState.attach`, so KVO mirrors the restored URL.
		//
		// INVARIANT: a restore is ALWAYS followed by the explicit load `updateUIView` issues
		// (the fresh Coordinator has no `lastLoadedGeneration`, so it cannot dedup), and that load
		// supersedes the restore navigation. This matters and must not be "optimised" away as a
		// redundant second navigation: restoring a session navigates the current back-forward item
		// with cache-permissive semantics, so a restore alone would happily re-serve the very
		// document the rebuild is trying to escape. The restore navigation dies with
		// NSURLErrorCancelled, which `WebLoadFailure.classify` ignores by design.
		//
		// Consumed on read: makeUIView also runs for ordinary identity changes (tab/mode switch),
		// and a stale session must never be restored over a healthy live one.
		if let sessionState = browserState.consumePendingSessionState() {
			webView.interactionState = sessionState
		}

		// No initial load here: SwiftUI guarantees updateUIView runs right after makeUIView,
		// so loading in both places fired a duplicate request (and this path bypassed the
		// withHTTPS/browserInputType normalization).
        return webView
    }

	public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
		// Subscriptions-only teardown: with the web tab being the only tab this never
		// fires today, but it must stay correct if tabOrder grows. Deliberately does NOT
		// detach the renderer's webView (a WebSnapshotRenderer, held weak) — the snapshot
		// ref is detection's concern and clearing it on a transient rebuild would break
		// takeSnapshot mid-detection.
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

		// Direct local-file load (AIA-0316 UI-test harness): a `file://` URL has no host and would
		// be mangled by `withHTTPS` / classified as a search term in the string path below, so it
		// must use `loadFileURL`. Read access is scoped to the file itself. Dispatched before the
		// `browserInputType` switch; `nil` for every normal load.
		if let fileURL = request.fileURL {
			let navigation = uiView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
			browserState.navigationIssued(navigation)
			context.coordinator.lastLoadedGeneration = request.generation
			return
		}

        func load(_ urlString: String) {
			// Host check is defense-in-depth (browserInputType only classifies
			// host-carrying input as .url): a host-less URL like "https://" would
			// issue a navigation that is guaranteed to fail.
            guard let url = URL(string: urlString.withHTTPS), url.host != nil else {
				// Fail open: a pending user load would otherwise strand the
				// address-display gate with no navigation to ever settle it.
				browserState.navigationIssued(nil)
				return
			}
			// Synchronous load: updateUIView already runs on the main thread, and the
			// returned navigation token keys the user-load display gate.
			// The request's cache policy is normally the protocol default; AIA-0509's rebuild rung
			// sets `.reloadIgnoringLocalCacheData` so the recovered page cannot come from cache.
			let navigation = uiView.load(URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: 60))
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

		// AIA-0509: navigation identity for failure publication. Recorded for EVERY navigation,
		// not just user-initiated ones — recovery loads and restore-lastPage loads never reach
		// `navigationIssued`, so this is the only token that covers them.
		// swiftlint:disable:next implicitly_unwrapped_optional
		public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			browserState?.navigationStarted(navigation, from: webView)
		}

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.loadStatusChanged?(true, nil)
			browserState?.navigationSettled(navigation, error: nil)
			browserState?.navigationCommitted(navigation, from: webView)
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.loadStatusChanged?(false, nil)

			guard let url = webView.url, let domain = url.host else {
				return
			}

			func removeJSObjects_agsCuzkCz() {
				// Optional-chained: the compass is queried at didFinish, before the ESRI app has
				// necessarily rendered it, so an unguarded `.remove()` on a null result threw on
				// every load and logged a spurious error (AIA-0509).
				let jsRemoveButton = "document.querySelector('.esri-component.esri-compass.esri-widget')?.remove();"
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
			// Post-commit: the committed document is the failed page itself (AIA-0552).
			browserState?.navigationFailed(navigation, error: error, provisional: false, from: webView)
        }

		// DNS/no-network failures and a superseded load's NSURLErrorCancelled arrive
		// here, not in didFail — without this the user-load display gate would strand.
		// swiftlint:disable:next implicitly_unwrapped_optional
		public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			parent.loadStatusChanged?(false, error)
			browserState?.navigationSettled(navigation, error: error)
			// Provisional: the previously committed page is still fully rendered, so over live
			// content this publishes nothing (AIA-0552).
			browserState?.navigationFailed(navigation, error: error, provisional: true, from: webView)
		}

		/// WebKit's content process died. This is the only dedicated signal — no navigation
		/// delegate error accompanies it — so without this the web view goes blank, `browserState`
		/// never settles, nothing is logged, and nothing ever recovers (AIA-0509).
		public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
			browserState?.webContentProcessDidTerminate(from: webView)
		}

		// MARK: - WKUIDelegate (JavaScript dialogs)

		// Without these, pages calling alert/confirm/prompt are silently suppressed.
		// UIAlertController is presented from the web view's own window, which works on
		// iOS, iPadOS, and the iPad-on-Mac build alike. Every path calls the completion
		// handler — WebKit hangs the page's JavaScript otherwise.

		// Signatures must match the SDK requirement exactly (incl. @MainActor @Sendable
		// on the completion handlers) — a "nearly matching" method is not a protocol
		// witness and the dialogs would be silently suppressed again.
		@MainActor
		public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
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

		@MainActor
		public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
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

		@MainActor
		public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
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
