//
//  BrowserState.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import Foundation
import WebKit
import Combine

/// A user-initiated load request with identity: re-submitting the same string after the
/// page drifted away (History API) must still perform a real load, so the web view dedups
/// on `generation`, never on the input string.
/// Fully public because `MLWebView`'s public initializer takes it.
public struct LoadRequest: Equatable, Sendable {
	/// Raw user input; normalization (https prefix, search fallback) happens at load time.
	public let input: String
	/// Bumped on every submit / history pick.
	public let generation: UInt64
	/// When set, the request is a direct local-file load (`loadFileURL`), bypassing the string
	/// classification in `MLWebView`. UI-test harness only (AIA-0316); `nil` for every normal load.
	public let fileURL: URL?

	public init(input: String, generation: UInt64, fileURL: URL? = nil) {
		self.input = input
		self.generation = generation
		self.fileURL = fileURL
	}

	public static let initial = LoadRequest(input: "", generation: 0)

	public func next(_ input: String) -> LoadRequest {
		LoadRequest(input: input, generation: generation + 1)
	}

	/// A direct local-file load. `input` carries the URL string for display/dedup only; the load
	/// is performed via `WKWebView.loadFileURL`, not the string path.
	public func nextFile(_ url: URL) -> LoadRequest {
		LoadRequest(input: url.absoluteString, generation: generation + 1, fileURL: url)
	}
}

/// Mirrors the live `WKWebView` navigation state (URL, back/forward, loading) and carries
/// browser navigation intents. KVO on `\.url` is the AIA-0044 fix: it also fires for
/// same-document History-API navigations (map pans), which never reach the navigation
/// delegate. One instance, owned by `AppState`; views send intents.
@MainActor
final class BrowserState: ObservableObject {
	/// The web view's actual URL, mirrored raw.
	@Published private(set) var currentURL: URL?
	/// What the address bar shows: the requested URL while a user-initiated load is
	/// pending, otherwise the throttled actual URL.
	@Published private(set) var displayedURL: URL?
	@Published private(set) var canGoBack = false
	@Published private(set) var canGoForward = false
	@Published private(set) var isLoading = false

	private let settings: Settings
	private weak var webView: WKWebView?
	private var subscriptions: Set<AnyCancellable> = []
	/// Token of the latest user-requested navigation. The display gate clears only when
	/// this exact navigation settles (commit or failure) — never by URL comparison, so a
	/// superseded load's cancellation cannot open the gate early.
	private var pendingNavigation: WKNavigation?
	private(set) var isUserLoadPending = false

	init(settings: Settings) {
		self.settings = settings
	}

	// MARK: - Web view lifecycle

	/// Idempotent: cancels any prior web view's mirrors first, so a `makeUIView` re-run
	/// is safe and the old web view stops publishing.
	func attach(_ webView: WKWebView) {
		subscriptions.removeAll()
		self.webView = webView

		// One KVO observation feeds all three URL paths. A CurrentValueSubject (not
		// .share()) so every downstream gets the current value regardless of
		// subscription order.
		let urlSubject = CurrentValueSubject<URL?, Never>(webView.url)
		webView.publisher(for: \.url)
			.removeDuplicates()
			.subscribe(urlSubject)
			.store(in: &subscriptions)

		urlSubject
			.receive(on: DispatchQueue.main)
			.sink { [weak self] url in
				self?.urlChanged(url)
			}
			.store(in: &subscriptions)

		// Persistence path: lastPage lands in UserDefaults (Settings.didSet), so it
		// follows a settled signal — map SPAs rewrite the URL many times per gesture,
		// and per-emission writes would churn storage. Trade-off: a kill within the
		// settle window loses at most the final pan step.
		urlSubject
			.debounce(for: .seconds(1), scheduler: DispatchQueue.main)
			.sink { [weak self] url in
				self?.persistLastPage(url)
			}
			.store(in: &subscriptions)

		// Display path: throttled (latest wins) so a map firing replaceState per
		// inertial-move frame cannot thrash the address bar, yet the bar stays live.
		urlSubject
			.throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
			.sink { [weak self] url in
				guard let self, self.isUserLoadPending.not else { return }
				self.displayedURL = url
			}
			.store(in: &subscriptions)

		webView.publisher(for: \.canGoBack)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] value in
				self?.canGoBack = value
			}
			.store(in: &subscriptions)

		webView.publisher(for: \.canGoForward)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] value in
				self?.canGoForward = value
			}
			.store(in: &subscriptions)

		webView.publisher(for: \.isLoading)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] value in
				self?.isLoading = value
			}
			.store(in: &subscriptions)
	}

	/// Teardown counterpart for `attach`, identity-guarded so a stale dismantle cannot
	/// detach a newer web view. Deliberately leaves `WebViewRenderer.webView` alone — the
	/// snapshot ref is detection's concern and the mirrors feed only browser chrome.
	func cancelSubscriptions(if webView: WKWebView) {
		guard self.webView === webView else { return }
		subscriptions.removeAll()
		self.webView = nil
	}

	// MARK: - Intents

	func goBackTapped() {
		webView?.goBack()
	}

	func goForwardTapped() {
		webView?.goForward()
	}

	func reloadTapped() {
		webView?.reload()
	}

	func stopTapped() {
		webView?.stopLoading()
		// stopLoading does not reliably emit a delegate callback for the cancelled
		// navigation; release the display gate here so it cannot stick.
		isUserLoadPending = false
		pendingNavigation = nil
		displayedURL = currentURL
	}

	/// A submit or history pick is about to issue a load. Gates the display stream
	/// (the bar shows the request, not a stale KVO emission) until that navigation
	/// settles. Callers only invoke this for loadable input (`.url` / `.searchTerm`).
	func userLoadRequested(_ input: String) {
		isUserLoadPending = true
		pendingNavigation = nil
		// isRestorable: defense-in-depth — only host-carrying http(s) URLs may be
		// shown as the request (browserInputType should already guarantee it).
		if input.browserInputType == .url,
		   let requested = URL(string: input.withHTTPS),
		   isRestorable(requested) {
			displayedURL = requested
		}
		// Search terms keep the previous display until the search page commits.
	}

	// MARK: - Navigation identity (gate clearing)

	/// Called from the load site with the token `WKWebView.load(_:)` returned.
	func navigationIssued(_ navigation: WKNavigation?) {
		guard isUserLoadPending else { return }
		if let navigation {
			pendingNavigation = navigation
		} else {
			// Should not happen for http(s) loads; fail open so the gate cannot
			// stick — and resync the display, since no navigation will ever
			// update KVO for the requested URL it may be showing.
			isUserLoadPending = false
			displayedURL = currentURL
		}
	}

	/// Called from didCommit / didFailProvisionalNavigation / didFail. Settles carrying
	/// an unrecorded token (an older navigation) are ignored.
	func navigationSettled(_ navigation: WKNavigation?, error: Error?) {
		guard isUserLoadPending,
			  let pending = pendingNavigation,
			  navigation === pending else { return }
		isUserLoadPending = false
		pendingNavigation = nil
		displayedURL = currentURL
	}

	// MARK: - Mirroring

	private func urlChanged(_ url: URL?) {
		currentURL = url
		// WebKit does not reliably emit KVO for canGoBack/canGoForward on
		// same-document (History API) navigations; re-read them on every URL change.
		if let webView {
			canGoBack = webView.canGoBack
			canGoForward = webView.canGoForward
		}
	}

	/// Restorable ≠ displayed: persisting from the (debounced) KVO stream instead of
	/// didFinish makes "reopen last page" restore the exact map position, but only URLs
	/// that can actually be reopened qualify.
	private func persistLastPage(_ url: URL?) {
		guard let url, isRestorable(url), settings.lastPage != url else { return }
		settings.lastPage = url
	}

	private func isRestorable(_ url: URL) -> Bool {
		url.host != nil && (url.scheme == "https" || url.scheme == "http")
	}
}
