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
	/// Cache policy for the issued `URLRequest`. Defaults to the protocol's own policy, so every
	/// existing call site is unchanged; AIA-0509's rebuild rung sets
	/// `.reloadIgnoringLocalCacheData`, because recovering from a poisoned cached document is the
	/// entire point of that rung and `MLWebView` would otherwise hardcode the default.
	public let cachePolicy: URLRequest.CachePolicy

	public init(
		input: String,
		generation: UInt64,
		fileURL: URL? = nil,
		cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
	) {
		self.input = input
		self.generation = generation
		self.fileURL = fileURL
		self.cachePolicy = cachePolicy
	}

	public static let initial = LoadRequest(input: "", generation: 0)

	public func next(_ input: String, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> LoadRequest {
		LoadRequest(input: input, generation: generation + 1, cachePolicy: cachePolicy)
	}

	/// A direct local-file load. `input` carries the URL string for display/dedup only; the load
	/// is performed via `WKWebView.loadFileURL`, not the string path.
	public func nextFile(_ url: URL) -> LoadRequest {
		LoadRequest(input: url.absoluteString, generation: generation + 1, fileURL: url)
	}
}

/// A request to rebuild the `WKWebView` (AIA-0509 recovery rung 2). Identity-bearing so a view can
/// tell a new request from a repeat of one it already served.
struct WebViewRebuildRequest: Equatable {
	/// Bumped per request; drives the web view's SwiftUI `.id`.
	let generation: UInt64
	/// The page the rebuilt web view must land on, with caching bypassed.
	let url: URL
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
	/// The reachability-class load failure currently worth showing the user, or `nil`.
	/// Views mirror this into `@State`; see `WebScreen`.
	@Published private(set) var loadFailure: WebLoadFailure?

	private let settings: Settings
	private weak var webView: WKWebView?
	private var subscriptions: Set<AnyCancellable> = []
	/// Kept apart from `subscriptions`, which `attach(_:)` clears on every web-view rebuild — the
	/// lifecycle subscription must outlive those.
	private var lifecycleSubscriptions: Set<AnyCancellable> = []
	/// Token of the latest user-requested navigation. The display gate clears only when
	/// this exact navigation settles (commit or failure) — never by URL comparison, so a
	/// superseded load's cancellation cannot open the gate early.
	private var pendingNavigation: WKNavigation?
	private(set) var isUserLoadPending = false

	// MARK: - AIA-0509 recovery

	/// The most recently *started* navigation, user-initiated or not. Failure publication is keyed
	/// on it because WebKit guarantees no ordering between a post-commit `didFail` on navigation A
	/// and a `didCommit` on navigation B — without the identity check, A's late failure would paint
	/// an overlay over the page B just loaded successfully.
	private var latestNavigation: WKNavigation?
	private var recoveryPolicy = WebContentRecoveryPolicy()
	/// When the in-flight rung started, or `nil` when none is. Set before calling WebKit so two
	/// triggers (becoming active, a manual retry) cannot both fire a rung.
	///
	/// A timestamp rather than a bool because the interesting failure is a rung that never calls
	/// back at all — precisely the wedge being recovered from. A plain flag would then stay set
	/// forever and no automatic recovery would ever run again for the rest of the session.
	private var recoveryStartedAt: Date?
	/// How long a rung may run before it is presumed dead and another may start.
	private static let recoveryStallTimeout: TimeInterval = 30
	/// Whether the pending rebuild is allowed to restore the captured session. Decided when the
	/// rung is chosen; read when the view invalidates the outgoing web view.
	private var pendingRebuildRestoresSession = false
	/// The URL a retry should actually load: the one that failed, which for a provisional failure
	/// is NOT what the web view currently holds. Falls back to the last reopenable URL.
	private var retryTarget: URL?
	/// Last mirrored URL that is actually reopenable. Recovery targets this rather than
	/// `currentURL`, which KVO drives to `nil` when the content process dies.
	private(set) var lastRestorableURL: URL?
	/// `WKWebView.interactionState`, captured off the live instance in `webViewInvalidated()` and
	/// consumed exactly once by the next `makeUIView`. Named `sessionState` because
	/// `interactionState` already means `ContentInteractionState` across `DetectableView`.
	/// In memory only — never persisted, so a session that wedges the renderer cannot outlive the
	/// process.
	private var pendingSessionState: Any?
	/// Set when the browser wants a rebuild; `WebScreen` observes it and bumps the web view's
	/// SwiftUI identity.
	@Published private(set) var rebuildRequest: WebViewRebuildRequest?

	/// - Parameter activeNotification: the "app became active" notification to retry on. Injected
	///   as a name rather than read from `UIApplication` so this file stays free of UIKit — a
	///   `*State` type importing UIKit fails `testStateTypesAvoidSwiftUIImports_Aspirational`.
	///   `nil` (the default, used by tests) subscribes to nothing.
	init(settings: Settings, activeNotification: Notification.Name? = nil) {
		self.settings = settings
		guard let activeNotification else { return }
		NotificationCenter.default
			.publisher(for: activeNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.applicationDidBecomeActive()
			}
			.store(in: &lifecycleSubscriptions)
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
	/// detach a newer web view. Deliberately leaves the renderer's `webView` alone — the
	/// snapshot ref is detection's concern and the mirrors feed only browser chrome.
	func cancelSubscriptions(if webView: WKWebView) {
		guard self.webView === webView else { return }
		subscriptions.removeAll()
		self.webView = nil
	}

	// MARK: - Intents

	// Back / Forward / Reload are user intent exactly as an address-bar submit is, so they
	// replenish the recovery budget too — otherwise a deliberate navigation after an exhausted
	// ladder would surface failure immediately instead of trying to recover.
	func goBackTapped() {
		recoveryPolicy.userDidNavigate()
		webView?.goBack()
	}

	func goForwardTapped() {
		recoveryPolicy.userDidNavigate()
		webView?.goForward()
	}

	func reloadTapped() {
		recoveryPolicy.userDidNavigate()
		loadFailure = nil
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
		// Deliberate navigation replenishes the recovery budget and dismisses any failure UI:
		// automatic recovery is bounded, the user's own intent is not.
		recoveryPolicy.userDidNavigate()
		loadFailure = nil
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

	// MARK: - Failure publication (AIA-0509)
	//
	// Deliberately separate from `navigationSettled` above, which early-returns unless
	// `isUserLoadPending`. The paths this ticket is about never set that flag: the
	// restore-`lastPage` load is explicitly "not a user load", in-page link taps aren't either,
	// and recovery loads bypass `updateUIView`'s generation path so they never call
	// `navigationIssued` at all. Routing failure publication through that gate would therefore
	// publish nothing for exactly the scenario reported. The gate's own guard stays untouched —
	// it is load-bearing for AIA-0296's superseded-load correctness.

	/// A navigation has begun. Records identity and clears any failure UI, so the overlay
	/// disappears the moment a retry is in flight rather than only once it succeeds.
	func navigationStarted(_ navigation: WKNavigation?, from webView: WKWebView? = nil) {
		guard isCurrent(webView) else { return }
		latestNavigation = navigation
		loadFailure = nil
	}

	/// A navigation committed: the page is live, so recovery is no longer in flight.
	func navigationCommitted(_ navigation: WKNavigation?, from webView: WKWebView? = nil) {
		guard isCurrent(webView), isLatest(navigation) else { return }
		recoveryStartedAt = nil
		retryTarget = nil
		loadFailure = nil
	}

	/// A navigation failed. Publishes only reachability-class failures (see `WebLoadFailure`) and
	/// only for the newest navigation.
	func navigationFailed(_ navigation: WKNavigation?, error: Error, from webView: WKWebView? = nil) {
		guard isCurrent(webView), isLatest(navigation) else { return }
		recoveryStartedAt = nil
		guard var failure = WebLoadFailure.classify(error) else { return }
		if failure.retryURL == nil {
			failure = WebLoadFailure(kind: failure.kind, retryURL: lastRestorableURL)
		}
		retryTarget = failure.retryURL
		loadFailure = failure
	}

	/// Whether a callback belongs to the newest navigation.
	///
	/// The guard is deliberately narrower than "identity must match": it only bites when **both**
	/// tokens exist. A `nil` incoming token (WebKit returned no `WKNavigation` for the load) and a
	/// `nil` `latestNavigation` (nothing started yet, or `webViewInvalidated()` just cleared it —
	/// precisely when a stranded failure still needs to surface) both pass. What it does rule out
	/// is the case it exists for: a late `didFail` for a superseded navigation arriving after a
	/// newer one has already committed, which would otherwise overlay a page that loaded fine.
	/// Whether a delegate callback came from the web view this state is currently attached to.
	///
	/// A `.id()` rebuild leaves the outgoing web view and its Coordinator alive briefly, and their
	/// late callbacks target the same shared `BrowserState`. Without this, a dying instance could
	/// clear a valid overlay, reset the new instance's navigation identity, or spend recovery
	/// budget against a web view that no longer exists. `nil` means the caller did not identify
	/// itself (tests calling the state directly) and is trusted.
	private func isCurrent(_ candidate: WKWebView?) -> Bool {
		candidate == nil || candidate === webView
	}

	private func isLatest(_ navigation: WKNavigation?) -> Bool {
		navigation == nil || latestNavigation == nil || navigation === latestNavigation
	}

	// MARK: - Web view invalidation & recovery (AIA-0509)

	/// The live `WKWebView` is about to become unusable — its content process died, or it is about
	/// to be replaced by a rebuild.
	///
	/// Clears every piece of state keyed to that instance. Without this the display gate strands:
	/// a user load in flight leaves `isUserLoadPending` true with a token that can never settle,
	/// and the throttled display sink stops updating `displayedURL` for the rest of the session.
	/// Called from *both* invalidation paths — a rebuild strands it exactly as a termination does.
	func webViewInvalidated() {
		// Captured off the still-live instance, and ONLY when a rebuild that may restore it is
		// what is invalidating us. Capturing unconditionally would leave a session sitting here
		// after a mere reload rung, to be restored later over a perfectly healthy web view by an
		// unrelated `makeUIView` (a tab or mode switch). Nil is fine — the rebuild then falls back
		// to a plain cache-busting URL load.
		if pendingRebuildRestoresSession, let webView {
			pendingSessionState = webView.interactionState
			pendingRebuildRestoresSession = false
		}
		isUserLoadPending = false
		pendingNavigation = nil
		latestNavigation = nil
		// Preserved when a rebuild is what is invalidating us: the view calls this *while* serving
		// the request, so clearing it here would disarm the stall deadline of the very rung just
		// armed, and a trigger arriving before the rebuilt view starts loading would find the
		// ladder idle and declare failure over a recovery still legitimately in flight.
		if rebuildRequest == nil {
			recoveryStartedAt = nil
		}
		displayedURL = currentURL
	}

	/// Consumed exactly once. `makeUIView` runs on any SwiftUI identity change — a tab or mode
	/// switch, not only a recovery rebuild — so a session left sitting here would eventually be
	/// restored over a perfectly healthy live one. Same one-shot discipline as
	/// `Settings.onboardingInitialPage`.
	func consumePendingSessionState() -> Any? {
		defer { pendingSessionState = nil }
		return pendingSessionState
	}

	/// WebKit's content process terminated. This is the only dedicated signal — no navigation
	/// delegate error accompanies it — so without handling it the web view simply goes blank and
	/// nothing ever recovers (AIA-0509).
	func webContentProcessDidTerminate(from webView: WKWebView? = nil) {
		guard isCurrent(webView) else { return }
		LoggingPolicy.error("WebView content process terminated; attempting recovery", logger: .ui)
		webViewInvalidated()
		attemptRecovery(now: Date())
	}

	/// The user tapped Try Again. Never rate-limited: resets the budget and performs the next rung,
	/// restarting at `.rebuild` once the ladder has been exhausted.
	func retryRequested() {
		let now = Date()
		loadFailure = nil
		// User intent pre-empts any in-flight rung, including one that stalled.
		recoveryStartedAt = nil
		perform(recoveryPolicy.manualRetry(now: now), now: now)
	}

	/// The app became active. The reported AIA-0509 scenario is a laptop reopened after sleep, so
	/// this is the trigger that matters; it acts only when something is actually broken.
	func applicationDidBecomeActive() {
		guard loadFailure != nil else { return }
		attemptRecovery(now: Date())
	}

	/// Runs the next rung, or leaves the failure UI standing when the ladder is exhausted.
	private func attemptRecovery(now: Date) {
		if let startedAt = recoveryStartedAt {
			// A rung that has not called back within the timeout is presumed dead — that is the
			// wedge itself — so another may start. Without this the ladder jams for the session.
			guard now.timeIntervalSince(startedAt) >= Self.recoveryStallTimeout else { return }
			LoggingPolicy.error("WebView recovery stalled with no callback; starting the next rung", logger: .ui)
			recoveryStartedAt = nil
		}
		guard let recovery = recoveryPolicy.nextRecovery(now: now) else {
			LoggingPolicy.error("WebView recovery budget exhausted; surfacing failure", logger: .ui)
			if loadFailure == nil {
				loadFailure = WebLoadFailure(kind: .unreachable, retryURL: lastRestorableURL)
			}
			return
		}
		perform(recovery, now: now)
	}

	private func perform(_ recovery: WebContentRecoveryPolicy.Recovery, now: Date) {
		switch recovery {
		case .reloadFromOrigin:
			// No web view to reload means the rung cannot run; surface the failure rather than
			// returning silently, which would consume the rung and show the user nothing.
			guard let webView else {
				loadFailure = WebLoadFailure(kind: .unreachable, retryURL: lastRestorableURL)
				return
			}
			recoveryStartedAt = now
			// A *provisional* navigation that failed never became the web view's URL, so the view
			// still holds the previous page: reloading it would re-fetch the page the user was
			// already on while the overlay names a different one. Retry the URL that actually
			// failed, and only fall back to reloading when it is the current page anyway.
			let navigation: WKNavigation?
			if let target = retryTarget, target != webView.url {
				LoggingPolicy.info("WebView recovery: reloading the failed URL", logger: .ui)
				navigation = webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
			} else {
				LoggingPolicy.info("WebView recovery: reloading from origin", logger: .ui)
				// `reloadFromOrigin`, not `reload`: end-to-end revalidation, because a stale cached
				// main document is one of the candidate causes and a plain reload may re-serve it.
				// The toolbar's own reload button keeps plain `reload()` semantics.
				navigation = webView.reloadFromOrigin()
			}
			if navigation == nil {
				// No navigation token means nothing will ever call back; fail now rather than
				// waiting for a delegate callback that cannot arrive.
				recoveryStartedAt = nil
				loadFailure = WebLoadFailure(kind: .unreachable, retryURL: retryTarget ?? lastRestorableURL)
			}
		case .rebuild:
			// Nothing reopenable means there is nothing to recover to; a rebuild would land on a
			// blank web view and lose the session for no gain.
			guard let url = retryTarget ?? lastRestorableURL else {
				loadFailure = WebLoadFailure(kind: .unreachable, retryURL: nil)
				return
			}
			recoveryStartedAt = now
			// Claimed before the view invalidates the outgoing web view, which is the only moment
			// the session can still be read off it.
			pendingRebuildRestoresSession = recoveryPolicy.consumeSessionRestore()
			LoggingPolicy.info(
				"WebView recovery: rebuilding the web view (restoring session: \(pendingRebuildRestoresSession))",
				logger: .ui
			)
			rebuildRequest = WebViewRebuildRequest(
				generation: (rebuildRequest?.generation ?? 0) + 1,
				url: url
			)
		}
	}

	/// The view has acted on the current rebuild request.
	func rebuildRequestHandled() {
		rebuildRequest = nil
	}

	/// The view could not act on the rebuild request — it arrived mid finding-capture, where
	/// replacing the web view would cancel the user's pick.
	///
	/// Releases the in-flight marker (the rung never ran, so nothing will call back to clear it)
	/// and leaves the failure UI standing so Try Again remains available.
	func rebuildRequestDeclined() {
		rebuildRequest = nil
		recoveryStartedAt = nil
		pendingRebuildRestoresSession = false
		if loadFailure == nil {
			loadFailure = WebLoadFailure(kind: .unreachable, retryURL: lastRestorableURL)
		}
	}

	// MARK: - Mirroring

	private func urlChanged(_ url: URL?) {
		currentURL = url
		// Sticky, and gated on the same reopenability rule persistence uses: KVO drives
		// `currentURL` to nil when the content process dies, and `file://` fixture URLs
		// (AIA-0316) / `about:blank` must never become recovery targets.
		if let url, isRestorable(url) {
			lastRestorableURL = url
		}
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
