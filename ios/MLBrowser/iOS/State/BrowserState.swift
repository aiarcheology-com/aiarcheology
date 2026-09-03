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

	// MARK: - AIA-0817 capture URL

	/// The URL of the document actually rendered on screen.
	///
	/// Neither existing URL is right for recording *what the user was looking at*.
	/// `displayedURL` is throttled and, during a user-initiated load, deliberately shows the
	/// **requested** address while the old page is still on screen. `currentURL` is raw KVO, which
	/// WebKit may already have moved to a provisional URL before that document exists.
	///
	/// So this tracks commits instead: set when a navigation commits, and advanced by the KVO
	/// stream only while no provisional navigation is in flight. That second half is what makes it
	/// follow a map pan — `pushState`/`replaceState` fire KVO and never commit, and there is no
	/// public same-document delegate callback to use instead (`WKNavigationDelegate` has none; the
	/// only such method is private SPI).
	///
	/// Accepted residual: a provisional load that neither commits nor fails leaves this frozen at
	/// the last committed page. That is the safe direction — stale, never a different page's URL.
	private(set) var committedURL: URL?

	/// Whether a provisional navigation is in flight, and which one.
	///
	/// Tracked by identity rather than as a bare flag because the settle callbacks are keyed on
	/// navigation identity; a plain boolean cleared by any callback could be cleared by a
	/// superseded load and let a provisional URL be recorded as committed.
	private var provisionalNavigation: WKNavigation?
	private var isProvisionalNavigationInFlight = false

	/// Brings the capture URL back in line with what the web view is showing.
	///
	/// Called when loading ends. A navigation that is stopped rather than completed may deliver no
	/// settle callback at all, which would otherwise leave the in-flight marker set and freeze the
	/// capture URL for the rest of the session — every later map pan silently unrecorded.
	private func resyncCommittedURL() {
		provisionalNavigation = nil
		isProvisionalNavigationInFlight = false
		if let url = webView?.url { committedURL = url }
	}

	/// Whether this document has been seen updating its own URL.
	///
	/// A map app that keeps its viewport in the fragment rewrites it as you pan. One that never
	/// touches it is not using it as state — and almost certainly does not read it on load either,
	/// so writing a viewport there produces a link that looks specific and opens on the default
	/// view. Measured on demotiles.maplibre.org, which ignores its hash in both directions.
	private(set) var hasObservedSameDocumentURLChange = false

	/// What a finding should record as its page.
	///
	/// Falls back to `currentURL` when nothing has been observed to commit yet — attaching to an
	/// already-loaded web view produces no commit callback, and a page is still on screen.
	var captureURL: URL? { committedURL ?? currentURL }

	/// Everything resolvable about the page right now: its URL always, and a coordinate when the
	/// live map or the URL can supply one.
	///
	/// Lives here because both inputs already do — the capture URL and the live `WKWebView`. Any
	/// other home would have to be handed the web view a second time.
	///
	/// The URL is read **before** awaiting the probe, so the recorded page is the one the user was
	/// on when they tapped rather than wherever the app drifted to while the page was being asked.
	func resolveCaptureLocation() async -> MapPageLocation {
		let url = captureURL
		let resolved = await MapLocationResolver.resolve(
			url: url,
			webView: webView,
			frames: mapFrames.childFrames,
			pageMaintainsItsURL: hasObservedSameDocumentURLChange
		)
		// The probe can take seconds, and the page can move during them — a redirect, a tapped
		// link, a pushState. What comes back then describes the document that is on screen NOW,
		// while the finding is being recorded against the one the user tapped on. Pairing them
		// would produce the most confident possible wrong answer: a precise coordinate under an
		// unrelated address (raised in review).
		//
		// The URL is kept and the coordinate dropped, rather than the whole result discarded,
		// because the URL is this feature's floor — it was read before the probe started and is
		// still the page the capture belongs to.
		guard captureURL == url else {
			return MapPageLocation(sourceURL: url)
		}
		return resolved
	}

	/// Frames that announced a map, so an iframed map can be probed (AIA-0817).
	let mapFrames = MapFrameRegistry()
	/// Whether the attached web view currently renders a committed document (AIA-0552). Set on
	/// commit; cleared when the instance is invalidated or replaced — and cleared at
	/// `navigationFailed`'s publish point, because a page the overlay has declared broken no
	/// longer counts as content worth protecting. Accepted residual: a post-commit failure
	/// *outside* the reachability allowlist returns at the classify guard and leaves the flag
	/// armed, so later provisional reachability failures over that (possibly broken) page stay
	/// silent — same class as the ticket's own silent-failure trade-off, and clearing before
	/// classify would be worse (a superseded load's cancellation would spend the flag).
	/// Deliberately tracked here rather than read off `webView.url`:
	/// at delegate-callback timing KVO may still report the provisional URL, and it goes `nil` on
	/// process death anyway — explicit commit tracking is deterministic and unit-testable.
	///
	/// INVARIANT: `loadFailure != nil ⇒ hasCommittedContent == false`. `navigationFailed` is the
	/// only publish path that may be *reached* with the flag true (it clears it as it publishes);
	/// every other `loadFailure` set site is reachable only after a prior publish or
	/// `webViewInvalidated()` has already cleared it. A new direct-set site must keep this true.
	private(set) var hasCommittedContent = false
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
		// Per-instance: a new web view has not committed anything yet, and carrying the previous
		// one's URL over would let a capture name a document this instance never showed.
		committedURL = nil
		hasObservedSameDocumentURLChange = false
		provisionalNavigation = nil
		isProvisionalNavigationInFlight = false
		subscriptions.removeAll()
		self.webView = webView
		// Every attach hands over a freshly constructed, blank instance (`makeUIView` never
		// re-attaches a content-bearing one), so it holds nothing committed until its first
		// didCommit (AIA-0552).
		hasCommittedContent = false

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
				// AIA-0817: the capture URL ignores KVO while the web view is loading, because
				// `load(_:)` publishes the REQUESTED url before the navigation starts. That window
				// also swallows a `replaceState` fired after the document commits but before it
				// finishes — a map that pans while its tiles are still arriving. Resynchronising
				// when loading ends recovers exactly that, and costs nothing otherwise.
				if value == false { self?.resyncCommittedURL() }
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
		// A different document is being fetched. Until it commits, KVO may report its URL while the
		// previous page is still what the user can see, so `committedURL` must stop following it.
		provisionalNavigation = navigation
		isProvisionalNavigationInFlight = true
		loadFailure = nil
	}

	/// A navigation committed: the page is live, so recovery is no longer in flight.
	func navigationCommitted(_ navigation: WKNavigation?, from webView: WKWebView? = nil) {
		guard isCurrent(webView), isLatest(navigation) else { return }
		// The document is now the one on screen, so its URL is what a finding should record.
		committedURL = (webView ?? self.webView)?.url ?? currentURL
		// A new document has its own habits; what the previous one did says nothing about it.
		hasObservedSameDocumentURLChange = false
		// Every frame handle belonged to the page being replaced.
		mapFrames.reset()
		clearProvisionalNavigation(navigation)
		recoveryStartedAt = nil
		retryTarget = nil
		loadFailure = nil
		hasCommittedContent = true
	}

	/// A navigation failed. Publishes only reachability-class failures (see `WebLoadFailure`) and
	/// only for the newest navigation.
	///
	/// `provisional` distinguishes the two delegate failure callbacks: a provisional failure
	/// leaves the previously committed page fully rendered and interactive, a post-commit one
	/// means the committed document is the failed page itself.
	func navigationFailed(
		_ navigation: WKNavigation?,
		error: Error,
		provisional: Bool = false,
		from webView: WKWebView? = nil
	) {
		guard isCurrent(webView), isLatest(navigation) else { return }
		// Cleared before every early return below. This method returns without publishing for an
		// unclassified error and for a provisional failure over committed content, and leaving the
		// in-flight marker set on those paths would freeze `committedURL` for the rest of the
		// session -- no later map pan would ever be recorded.
		clearProvisionalNavigation(navigation)
		recoveryStartedAt = nil
		guard var failure = WebLoadFailure.classify(error) else { return }
		// AIA-0552: never replace usable content with the opaque overlay. On-device detection and
		// classification keep working on the committed page, so any navigation intent that fails
		// provisionally over it — an offline submit, reload, or back/forward — fails silently by
		// design; the overlay is reserved for a screen with nothing worth keeping on it.
		if provisional && hasCommittedContent { return }
		// Publishing declares the committed document broken (a post-commit failure IS that
		// document), so it stops counting as content worth protecting. Without this, the retry
		// rung — or a fresh submit — failing provisionally afterwards would be suppressed, and
		// with `loadFailure` stuck nil the become-active ladder would never run again.
		hasCommittedContent = false
		if failure.retryURL == nil {
			failure = WebLoadFailure(kind: failure.kind, retryURL: lastRestorableURL)
		}
		retryTarget = failure.retryURL
		loadFailure = failure
	}

	/// Forgets the in-flight provisional navigation once it has settled.
	///
	/// Identity-checked: a superseded load settling late must not clear the marker belonging to the
	/// navigation that replaced it.
	private func clearProvisionalNavigation(_ navigation: WKNavigation?) {
		guard isProvisionalNavigationInFlight, navigation === provisionalNavigation else { return }
		isProvisionalNavigationInFlight = false
		provisionalNavigation = nil
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
		// AIA-0817: the in-flight marker belongs to a navigation on an instance that no longer
		// exists, so nothing will ever settle it. Left set, a content-process death mid-load would
		// freeze the capture URL until some later navigation happened to commit.
		provisionalNavigation = nil
		isProvisionalNavigationInFlight = false
		// The committed URL belongs to a document on an instance that is gone. Left in place, a
		// finding captured before the replacement lands could name the previous page.
		committedURL = nil
		hasObservedSameDocumentURLChange = false
		// Whichever path invalidated the instance (rebuild or process death), its committed
		// document does not survive it (AIA-0552).
		hasCommittedContent = false
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
		// Named, because this is the one failure that is almost always the page's fault — a renderer
		// killed by what it was rendering. The host groups the issue; the address reproduces it.
		let page = webView?.url ?? committedURL
		let site = page?.host ?? "unknown"
		LoggingPolicy.error(
			"WebView content process terminated; attempting recovery [site: \(site)]",
			page: page,
			logger: .ui
		)
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
		// A same-document navigation -- the History-API rewrite a map fires on every pan -- changes
		// the URL without any commit, so this is the only place it can be picked up.
		//
		// Three conditions, and the third is the subtle one. `WKWebView.load(_:)` publishes the
		// REQUESTED url through KVO synchronously, as a pending API request, BEFORE
		// `didStartProvisionalNavigation` arrives -- so the in-flight marker alone is too late and
		// this would latch a page the user never saw, then freeze on it for the whole fetch.
		// `isLoading` is already true at that point, which is what closes the gap. A same-document
		// rewrite sets none of the three.
		let isFetchingAnotherDocument = isProvisionalNavigationInFlight
			|| isUserLoadPending
			|| webView?.isLoading == true
		if isFetchingAnotherDocument.not {
			// A change with no navigation behind it is the page rewriting its own address.
			if committedURL != nil, url != committedURL { hasObservedSameDocumentURLChange = true }
			committedURL = url
		}
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
