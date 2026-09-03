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
	var rendererAttached: (() -> Void)?
	@EnvironmentObject var browserState: BrowserState
	var request: LoadRequest
    var loadStatusChanged: ((Bool, Error?) -> Void)?
	var interactionStateChanged: ((ContentInteractionState) -> Void)?

	init(
		_ request: LoadRequest,
		renderer: WebSnapshotRenderer,
		rendererAttached: (() -> Void)? = nil,
		loadStatusChanged: ((Bool, Error?) -> Void)? = nil,
		interactionStateChanged: ((ContentInteractionState) -> Void)? = nil
	) {
		self.request = request
		self.renderer = renderer
		self.rendererAttached = rendererAttached
        self.loadStatusChanged = loadStatusChanged
        self.interactionStateChanged = interactionStateChanged
    }

    public func makeCoordinator() -> Self.Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> WKWebView {
		let contentController = Self.makeUserContentController()
		contentController.add(context.coordinator, name: "interactionHandler")
		// AIA-0817: every frame announces itself here, which is the only way to obtain a
		// `WKFrameInfo` for a child frame — WebKit has no API to enumerate them.
		contentController.add(context.coordinator, name: "aiaMapFrame")
		// AIA-0827: how many errors the page's own scripts threw. Registered separately from the map
		// registry because it must keep working when the map parser is switched off — that switch
		// exists for bisecting a broken page, which is precisely when this count is worth having.
		contentController.add(context.coordinator, name: "aiaPageDiagnostics")

		let config = WKWebViewConfiguration()
		config.userContentController = contentController

		return makeWebView(config: config, context: context)
	}

	/// Every user script the app injects, in one place.
	///
	/// Split out of `makeUIView` so a test can assert against the scripts the app *actually ships*
	/// rather than a configuration the test built for itself. AIA-0817 shipped inert precisely
	/// because its registry was installed only by its own tests, which could never notice.
	static func makeUserContentController() -> WKUserContentController {
		let contentController = WKUserContentController()

		// Inject JavaScript to detect touch/pointer events
		let touchDetectionScript = WKUserScript(
			source: """
			(function() {
				let interactionTimeout = null;
				var isInteracting = false;

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

		// AIA-0817: records map instances as their libraries construct them, so a finding saved on
		// a map page can ask the live map where it is looking.
		//
		// Must be `.atDocumentStart`: it has to be watching for `L`, `ol` and the rest before the
		// page's own scripts assign them, and at `.atDocumentEnd` every one of those assignments has
		// already happened. (It watches by polling — an earlier version installed accessor
		// properties on `window` and broke bundled applications outright.)
		//
		// Injected into every frame, because portals and documentation shells routinely put the map
		// in an iframe. Each frame announces itself through the `aiaMapFrame` handler below, which
		// is the only way to obtain a `WKFrameInfo` — WebKit cannot enumerate frames — and the probe
		// then asks those frames as well as the main one.
		if AppEnvironment.isMapLocationParserDisabled.not {
			contentController.addUserScript(
				WKUserScript(
					source: MapProbeScript.registry,
					injectionTime: .atDocumentStart,
					forMainFrameOnly: false
				)
			)
		}

		// AIA-0827: counts the page's own script errors. Deliberately OUTSIDE the map-parser switch
		// above — the switch is what a tester flips to find out whether our injection broke a page,
		// and a diagnostic that disappears in exactly that experiment is worth nothing.
		contentController.addUserScript(
			WKUserScript(
				source: Self.pageDiagnosticsScript,
				injectionTime: .atDocumentStart,
				forMainFrameOnly: false
			)
		)

		return contentController
	}

	/// Counts the page's own uncaught errors and reports the running total.
	///
	/// Reported at two fixed moments rather than per error: a page in a failure loop can throw
	/// hundreds, and one message per error would make the diagnostic its own performance problem.
	/// Two seconds catches the scripts that fail during startup — the case that leaves a blank page —
	/// and eight catches what fails while the app is wiring itself up afterwards.
	///
	/// Nothing but a number crosses the bridge. `event.message` routinely contains a URL, a selector
	/// or a fragment of the page's own source, and this runs on every page the user visits.
	///
	/// Wrapped whole in `try`: a diagnostic that can break a page is worse than no diagnostic
	/// (AIA-0827, and the lesson of the accessor-based registry before it).
	private static let pageDiagnosticsScript = """
	(function () {
	  try {
	    var count = 0;
	    function report() {
	      try {
	        if (count > 0 && window.webkit && window.webkit.messageHandlers
	            && window.webkit.messageHandlers.aiaPageDiagnostics) {
	          window.webkit.messageHandlers.aiaPageDiagnostics.postMessage(count);
	        }
	      } catch (e) {}
	    }
	    window.addEventListener('error', function () { count = count + 1; }, true);
	    window.addEventListener('unhandledrejection', function () { count = count + 1; }, true);
	    setTimeout(report, 2000);
	    setTimeout(report, 8000);
	  } catch (e) {}
	}());
	"""

	private func makeWebView(config: WKWebViewConfiguration, context: Context) -> WKWebView {
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
		rendererAttached?()
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
		/// When the navigation now in flight started, so each stage can say how long it took to
		/// reach. Keyed by nothing: `WKNavigation` is not reliably the same object across callbacks
		/// for every load, and one timestamp answers the question this exists for — "how long until
		/// something happened" — without pretending to track concurrent loads that a single web view
		/// does not have (AIA-0827).
		private var navigationStartedAt: Date?
		/// The highest error count any single frame has reported for the current load.
		///
		/// Not a page total. Each frame reports its OWN running count, twice, so summing the messages
		/// would count the same frame's errors again on its second report. The largest frame is the
		/// honest summary available from these messages, and it is what the log line says.
		private var worstFramePageErrors = 0

        init(_ parent: MLWebView) {
            self.parent = parent
        }

		// MARK: - WKScriptMessageHandler

		public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			// AIA-0817: every frame announces itself so an iframed map can be probed. This must come
			// BEFORE the interaction guard below, which returns for any other message name.
			if message.name == "aiaMapFrame" {
				browserState?.mapFrames.record(message.frameInfo)
				return
			}
			// How many errors the page threw, as a COUNT and never a message: an error string can
			// carry a URL or page content, and this runs on every page the user visits (AIA-0827).
			if message.name == "aiaPageDiagnostics" {
				guard let errors = (message.body as? NSNumber)?.intValue, errors > worstFramePageErrors else { return }
				worstFramePageErrors = errors
				// The WORST single frame, not a page total: each frame reports its own running count,
				// so adding them would double-count every repeat report from the same frame, and
				// keeping the maximum and calling it a total was simply wrong (raised in review).
				// "Errors" includes failed resource loads, because the listener is capturing — which
				// is wanted here, since a shell whose scripts 404 is exactly the blank-page case.
				LoggingPolicy.debug(
					"A frame reported \(errors) script or resource error(s) this load",
					logger: .ui
				)
				return
			}
			guard message.name == "interactionHandler",
				  let body = message.body as? String else { return }

			switch body {
			case "start":
				setScrolling(true)
			case "end":
				// The DOM's idea of "the touch ended" is not the same as "the content stopped
				// moving". A flick lifts the finger and the page keeps decelerating for as long as
				// the flick was hard; this message arrives 150 ms after `touchend`, squarely inside
				// that window. Publishing idle there tells detection the page is still, and the
				// resulting snapshot is of a frame the content has already scrolled past — boxes
				// drawn where the objects no longer are.
				//
				// It could not self-correct either: `scrollViewDidEndDecelerating` calls
				// `setScrolling(false)` too, and `setScrolling` returns early when the value has
				// not changed, so the genuine settle published nothing and the stale overlay stood
				// until the next timer tick.
				//
				// So defer to the scroll view while it is still moving. Both native callbacks below
				// end in `setScrolling(false)`, and neither can be missed: `didEndDragging` handles
				// the lift that does not decelerate, `didEndDecelerating` the one that does.
				let scrollView = message.webView?.scrollView
				if Self.domInteractionEndSettlesContent(
					isDragging: scrollView?.isDragging ?? false,
					isDecelerating: scrollView?.isDecelerating ?? false
				) {
					setScrolling(false)
				}
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

		/// Whether a DOM `end` message may publish idle, given what the scroll view is doing.
		///
		/// A value rather than an `if` at the call site, and for the reason this project extracts
		/// any such decision: `WKScriptMessage` has no public initialiser and `message.webView` is
		/// read-only, so the branch that consumes this cannot be reached from a test at all. The
		/// rule it encodes — a flick's `touchend` arrives while the page is still moving, and
		/// detection must not be told the content is still — is the kind that gets quietly inverted
		/// by a later edit, so it is stated where a test can hold it.
		///
		/// Absent motion state (no web view) settles: the pre-existing behaviour, and the safe
		/// direction — a missed idle strands the overlay until the next timer tick, whereas an
		/// early one paints boxes at coordinates the content has scrolled away from.
		static func domInteractionEndSettlesContent(isDragging: Bool, isDecelerating: Bool) -> Bool {
			isDragging == false && isDecelerating == false
		}

		private func setScrolling(_ value: Bool) {
			guard isScrolling != value else { return }
			isScrolling = value
			let state: ContentInteractionState = value ? .interacting : .idle
			parent.interactionStateChanged?(state)
		}

		// MARK: - Load diagnostics (AIA-0827)

		/// Milliseconds since the current navigation began, or `-1` when none was observed.
		private func elapsedMilliseconds() -> Int {
			guard let navigationStartedAt else { return -1 }
			return Int(Date().timeIntervalSince(navigationStartedAt) * 1000)
		}

		/// Counts what the finished document actually **rendered**, and says so when the answer is
		/// nothing.
		///
		/// The gap this fills: a load that *succeeds* and renders a blank page logs nothing at all, so
		/// "did it even load" could only be answered by guessing or by bisecting. Three separate map
		/// sites were reported blank during AIA-0817 testing and each cost an investigation to
		/// attribute — one of them to a stale cache, which no amount of reading the app could have
		/// revealed.
		///
		/// ## Rendered, not merely present
		/// Counting elements that *exist* gets this wrong in both directions, and both were found in
		/// review. A failed application shell routinely contains a hidden canvas, an icon sprite or a
		/// tracking pixel, so existence says "not blank" about a blank page; and a page that draws in
		/// an `<iframe>` or a `<video>` counts as blank when it is fine. So the check asks for a
		/// non-zero bounding box, over the six element kinds that can actually show something.
		///
		/// ## A refusal is not an absence
		/// A selector the page refuses to answer comes back as `-1`. Treating that as zero would
		/// report a page as blank on the strength of a measurement that never happened, and every
		/// such false positive becomes a Sentry issue. A refusal anywhere abandons the verdict.
		///
		/// ## Twice, not once
		/// `didFinish` is not the moment a single-page application has rendered — it is the moment its
		/// document finished loading, often before its first paint. Reporting on the first look would
		/// name every SPA. The verdict is only taken when a second look, a couple of seconds later,
		/// still finds nothing.
		private func reportRenderedContent(of webView: WKWebView) {
			// The host goes in the MESSAGE, so events group per site rather than fragmenting into one
			// issue per view; the whole address goes in the crash-service context, so a failure can be
			// reproduced by opening it.
			let page = webView.url
			let site = page?.host ?? "unknown"
			measureRenderedContent(of: webView) { first in
				guard let first else { return }
				guard first.drewNothing else {
					LoggingPolicy.debug("Page finished with content — \(first.counts)", logger: .ui)
					return
				}
				// Nothing yet. That is the ordinary state of a single-page application at `didFinish`,
				// so it is a reason to look again rather than a verdict.
				LoggingPolicy.debug("Page finished with nothing drawn yet — \(first.counts)", logger: .ui)
				// Weakly held: a second look is a diagnostic, and a diagnostic must not be the reason a
				// coordinator or its web view outlives the screen that owned them.
				DispatchQueue.main.asyncAfter(deadline: .now() + Self.blankPageConfirmationDelay) { [weak self, weak webView] in
					guard let self, let webView else { return }
					// A page that navigated away in the meantime is a different document, and its
					// emptiness is not this one's.
					guard webView.url == page else { return }
					self.measureRenderedContent(of: webView) { second in
						guard let second, second.drewNothing else {
							LoggingPolicy.debug(
								"Page drew after the first look — \(second?.counts ?? "no measurement")",
								logger: .ui
							)
							return
						}
						// `.error`, not `.warning`, and the difference is entirely where it lands: a
						// warning is a breadcrumb, visible only if a crash follows, and no crash
						// accompanies this. An error is a Sentry issue that can be looked up.
						//
						// The COUNTS are logged separately rather than carried in the message. Sentry
						// deduplicates on a signature built from the message, so varying numbers would
						// make every reload its own event; a message that varies only by site gives one
						// issue per broken site, which is the question being asked.
						LoggingPolicy.debug("Still nothing drawn — \(second.counts)", logger: .ui)
						LoggingPolicy.error("Web page rendered nothing [site: \(site)]", page: page, logger: .ui)
					}
				}
			}
		}

		/// How long to wait before believing an empty page.
		///
		/// Two seconds is the shortest interval that covered the application shells measured during
		/// AIA-0817 — ArcGIS templates are still wiring themselves up well after `didFinish`. It is a
		/// timer on a page that has already finished loading, so nothing is waiting on it.
		private static let blankPageConfirmationDelay: TimeInterval = 2

		/// One measurement of what is on screen. `nil` when the page could not be measured at all.
		private func measureRenderedContent(
			of webView: WKWebView,
			then handle: @escaping @MainActor (RenderedContentSummary?) -> Void
		) {
			// Bounded on purpose. `querySelectorAll` over six kinds is cheap; measuring every match is
			// not, on a page with thousands of images, and this runs on every load. The first forty
			// answer the question — a page with forty rendered elements is not blank.
			let script = """
			(function () {
			  try {
			    var visible = 0, refused = false, examined = 0;
			    var kinds = ['canvas', 'svg', 'img', 'video', 'iframe', 'object'];
			    for (var k = 0; k < kinds.length; k++) {
			      var nodes;
			      try { nodes = document.querySelectorAll(kinds[k]); } catch (e) { refused = true; continue; }
			      for (var i = 0; i < nodes.length && examined < 40; i++) {
			        examined = examined + 1;
			        try {
			          var box = nodes[i].getBoundingClientRect();
			          if (box.width > 0 && box.height > 0) { visible = visible + 1; }
			        } catch (e) { refused = true; }
			      }
			    }
			    // `innerText` is the expensive part: it can force layout and materialise the page's
			    // rendered text, and this runs on every load. It is only asked for when the answer is
			    // still in doubt — anything already visible settles the question without it.
			    var text = -1;
			    if (visible === 0) {
			      try {
			        text = (document.body && document.body.innerText) ? document.body.innerText.trim().length : 0;
			      } catch (e) { refused = true; }
			    }
			    return [visible, text, refused ? 1 : 0, examined];
			  } catch (e) {
			    return [-1, -1, 1, 0];
			  }
			}())
			"""
			webView.evaluateJavaScript(script) { value, error in
				if let error {
					// Not a warning: a document that refuses evaluation (a PDF, a plugin document, a
					// frame torn down between finishing and being asked) is ordinary.
					LoggingPolicy.debug(
						"Rendered-content check did not run: \(error.localizedDescription)",
						logger: .ui
					)
					handle(nil)
					return
				}
				handle(RenderedContentSummary(value))
			}
		}

		// MARK: - WKNavigationDelegate

		// AIA-0509: navigation identity for failure publication. Recorded for EVERY navigation,
		// not just user-initiated ones — recovery loads and restore-lastPage loads never reach
		// `navigationIssued`, so this is the only token that covers them.
		// swiftlint:disable:next implicitly_unwrapped_optional
		public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			// A page interaction can initiate navigation after the injected JavaScript has published
			// `.interacting`. Replacing the document cancels that document's delayed `end` callback,
			// so explicitly close the old document's interaction here. Otherwise every subsequent
			// detection snapshot is discarded until a native scroll/zoom happens to publish idle.
			if isScrolling {
				LoggingPolicy.debug("Navigation cleared active web content interaction", logger: .ui)
			}
			// The clock for the stage lines below. A blank page is indistinguishable from a slow one
			// in a log that records neither (AIA-0827).
			navigationStartedAt = Date()
			worstFramePageErrors = 0
			LoggingPolicy.debug("Navigation stage: provisional load started", logger: .ui)
			setScrolling(false)
			browserState?.navigationStarted(navigation, from: webView)
		}

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
			LoggingPolicy.debug("Navigation stage: document committed after \(elapsedMilliseconds())ms", logger: .ui)
            parent.loadStatusChanged?(true, nil)
			browserState?.navigationSettled(navigation, error: nil)
			browserState?.navigationCommitted(navigation, from: webView)
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			LoggingPolicy.debug("Navigation stage: load finished after \(elapsedMilliseconds())ms", logger: .ui)
			parent.loadStatusChanged?(false, nil)
			reportRenderedContent(of: webView)

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

/// What a finished document actually **rendered**, as measured in the page and carried back as
/// numbers.
///
/// A type rather than a tuple inside a closure so the verdict — "this page rendered nothing" — is a
/// decision a test can put both ways. The bug this exists for was reported three times during
/// AIA-0817 testing and never once appeared in a log; a rule living inside a completion handler
/// would be just as unexaminable.
struct RenderedContentSummary: Equatable {
	/// Elements with a non-zero bounding box, across the six kinds that can show something.
	let visible: Int
	/// Trimmed length of the body's rendered text, or `-1` if it could not be read.
	let text: Int
	/// Whether any measurement was refused. A page can refuse a selector, and a refusal is not an
	/// absence.
	let refused: Bool
	/// How many elements were examined before the cap.
	let examined: Int

	/// Parses the array the page returns, refusing anything else.
	///
	/// The page is untrusted: a document that returns a string, a short array, or floats is not a
	/// measurement, and reporting a blank page because the answer was malformed would be a false
	/// alarm on exactly the pages that are already unusual.
	init?(_ value: Any?) {
		guard let numbers = value as? [Any], numbers.count == 4 else { return nil }
		// Whole numbers only. `intValue` alone truncates — 0.5 became 0, so a fractional answer read
		// as an empty page — and the comment above claimed floats were refused while the code
		// accepted them (raised in review). These are counts; a count is an integer.
		let counts = numbers.compactMap { candidate -> Int? in
			guard let number = candidate as? NSNumber else { return nil }
			let whole = number.intValue
			guard Double(whole) == number.doubleValue else { return nil }
			return whole
		}
		guard counts.count == 4 else { return nil }
		visible = counts[0]
		text = counts[1]
		refused = counts[2] != 0
		examined = counts[3]
	}

	/// Nothing a person could see.
	///
	/// Three ways this is deliberately conservative, each from a defect found in review:
	///
	/// - **A refusal abandons the verdict.** A selector the page would not answer is not evidence of
	///   emptiness, and every false positive here becomes a Sentry issue.
	/// - **Rendered, not present.** `visible` counts only elements with a non-zero box, because a
	///   failed application shell routinely holds a hidden canvas, an icon sprite or a tracking
	///   pixel — existence would call a blank page full.
	/// - **Six kinds, not four.** `iframe`, `video` and `object` draw as surely as a canvas does, and
	///   a page that renders inside one of them is not blank.
	///
	/// Container `<div>`s are counted by neither: a shell renders its containers before its scripts
	/// run, so a page that failed to start still has plenty of them. That was the exact shape of the
	/// pages this was written for.
	var drewNothing: Bool {
		refused == false && visible == 0 && text == 0
	}

	var counts: String {
		"visible=\(visible) text=\(text) refused=\(refused) examined=\(examined)"
	}
}
