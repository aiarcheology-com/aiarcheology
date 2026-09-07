//
//  WebScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI
import OSLog
import StoreKit

@MainActor
struct WebScreen: Screen {
    @ViewBuilder
	static func content() -> some View {
		VStack {
			WebScreenView()
		}
	}

    @ViewBuilder
    static func barItems(position: ItemsPosition) -> some View {
        switch position {
        case .leading:
            GlobalToolbarLeading()
        case .trailing:
            GlobalToolbarTrailing()
        }
    }

	static func tabId() -> AppMode {
		.web
	}

	@ViewBuilder
	static func tabItem(selection: AppMode) -> some View {
		if tabId() == selection {
			Image(systemName: "map")
		} else {
			Image(systemName: "map").environment(\.symbolVariants, .none)
		}
		Text(L10n.Tab.web)
	}

}

enum HistoryError: Error {
	case fullHistory
}

/// The log level a WebView load error should be reported at.
enum WebViewLoadErrorLevel {
	case debug
	case error
}

/// Decides whether a WebView load error is a benign cancellation (downgrade to
/// `.debug`) or a genuine failure (`.error`, captured by Sentry).
///
/// `NSURLErrorCancelled` (-999) fires when a load is superseded by navigating away,
/// reloading, or a redirect — it is not a failure, so it was flooding Sentry as a
/// fake error (AIA-0296). Only this exact domain+code is downgraded; everything else
/// (no connection, timeout, DNS, TLS, etc.) still logs at `.error`. `URLError(.cancelled)`
/// is covered too via its `NSURLErrorDomain`/`-999` bridging.
func webViewLoadErrorLevel(for error: Error) -> WebViewLoadErrorLevel {
	let nsError = error as NSError
	if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
		return .debug
	}
	return .error
}

import Vision
struct WebScreenView: View {
	@Environment(\.managedObjectContext) var moc
	/// When true the address bar renders at the bottom (`.safeAreaInset`) instead of the
	/// top `.principal` slot. Computed once in `ContentView` so the two gates can't
	/// disagree on rotation; defaults to false (top bar) — see `bottomAddressBarActive`.
	@Environment(\.bottomAddressBarActive) private var bottomAddressBarActive
	@Environment(\.requestReview) private var requestReview
	/// Real vs. mock auth (AIA-0385); forwarded into the sign-in sheet across its boundary.
	@Environment(\.usesRealAuth) private var usesRealAuth
	/// iPad and Mac place BACK/FORWARD/RELOAD in the top bar; iPhone keeps them in the
	/// floating capsule, so the top bar has room for the address + Find (AIA-0294).
	private var showsTopBarNavigation: Bool { HostPlatform.current.isiPhone == false }
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var appState: AppState
	@State private var loadRequest = LoadRequest(input: "https://www.google.com", generation: 0)
	/// Drives the location sheet and records how it was opened. `item`-based so the mode is
	/// captured reliably at presentation — a separate bool read inside a `.sheet(isPresented:)`
	/// closure can lag the flip and present with the wrong content (AIA-0338).
	@State private var locationSheet: LocationSheetMode?

	/// How the location sheet was opened. `Int`-backed `Identifiable` so `.sheet(item:)` drives it.
	private enum LocationSheetMode: Int, Identifiable {
		case edit      // prefill the current URL for editing
		case compose   // start blank (the bottom bar's clear ✕)
		var id: Int { rawValue }
	}
	@State private var latestError: HistoryError?
	@State private var showAlert: Bool = false
	@State private var hasPerformedInitialAction = false
	/// UI-test introspection: which page the browser decided to load (home/last/blank).
	@State private var intendedPageKind = ""
	@State private var currentPageFile = ""
	@State private var showIdentifiers: Bool = false
	/// Positive "should the overlays animate" flag (= !settings.disableDetectionAnimations).
	/// Seeded on appear and kept live below; passed to DetectableView's leaf annotations.
	@State private var animateDetections: Bool = true
	@State private var tiling: TilingScheme = []
	/// Mirrors the "Tiled Borders" setting (AIA-0426) into local state so DetectableView can draw the
	/// per-tile debug outlines. Available in all builds, toggled from the Tiled Detection submenu.
	@State private var tiledBorders: Bool = false
	/// Mirrors `guide.ontheflyDetectionEnabled` (play/pause) so DetectableView can
	/// clear the classification presentation the moment detection stops (AIA-0374).
	@State private var detectionActive: Bool = false
	/// IDs of drivers currently registered per bucket. A model enabled mid-session registers its
	/// driver asynchronously; passes are snapshot-driven, so a newly registered driver would produce
	/// nothing until the next timer tick or interaction. When a new ID appears we fire one immediate
	/// snapshot so a just-enabled model runs on the current page right away.
	@State private var runningClassifierIDs: Set<UUID> = []
	@State private var runningDetectorIDs: Set<UUID> = []
	/// The tapped detection being saved; non-nil presents the save sheet.
	@State private var findingCapture: FindingCapture?
	/// Guards the asynchronous window between a centre alignment and the sheet appearing.
	@State private var isResolvingCapture = false
	/// Invalidates an asynchronous location resolution if the user keeps manipulating the page or
	/// cancels, so an old aligned frame can never present its form during a newer attempt.
	@State private var captureResolutionGeneration: UInt64 = 0
	/// Freezes DetectableView's displayed frame while the save sheet is up.
	@State private var isCapturingFinding: Bool = false
	/// Alignment mode (Find/Store button): the user moves web content until a displayed detection
	/// sits beneath the stationary centre crosshair.
	@State private var findPickActive: Bool = false

	/// Set by the save sheet when a finding is actually written, read once on its dismissal. The
	/// review prompt cannot stand in for this — it declines for its own reasons (AIA-0536).
	@State private var didSaveFinding = false

	/// The one-time contextual sign-in offer that follows a save (AIA-0536).
	@State private var showSignInOffer = false
	/// Mirror of DetectableView's displayed frame (updated on every apply/clear). Alignment mode
	/// reads the exact frame it displays, so its saved image and detected rectangle stay coherent.
	@State private var appliedFrame: AppliedDetectionFrame?
	/// Live width of the screen content area (== the navigation bar width). The `.principal`
	/// toolbar item collapses to its content width instead of filling on every idiom, so the
	/// principal cluster is sized explicitly from this (AIA-0294 follow-up). A proper custom
	/// top bar (`safeAreaInset`) is the real fix, tracked in AIA-0339; this is the stopgap.
	@State private var topBarWidth: CGFloat = 0
	/// Mirror of `BrowserState.loadFailure` (AIA-0509). Mirrored into `@State` rather than
	/// observing `BrowserState` here: `WebScreenView` holds only `appState`, and adding an
	/// `@EnvironmentObject` for the browser would subscribe this whole `DetectableView` tree to
	/// `currentURL`/`isLoading` churn — which SPAs emit per inertial map frame.
	@State private var loadFailure: WebLoadFailure?
	/// Bumped to give `MLWebView` a fresh SwiftUI identity, rebuilding the underlying `WKWebView`
	/// (AIA-0509 recovery rung 2).
	@State private var webViewGeneration: UInt64 = 0

	/// Horizontal space the leading (cpu ≈ 68pt) + trailing (find/detection/adjust ≈ 166pt)
	/// toolbar clusters and the bar's margins occupy. The principal footprint is the rest;
	/// inside it the address fills whatever the BACK/FORWARD/RELOAD buttons (iPad/Mac) leave.
	private static let principalSideReserve: CGFloat = 240
	/// Small floor to avoid a degenerate/zero footprint in extreme layouts.
	private static let minPrincipalWidth: CGFloat = 120
	/// Breathing room between the address cluster and each neighboring toolbar button.
	private static let principalGap: CGFloat = 12

	/// Explicit footprint for the `.principal` cluster, which won't stretch on any idiom.
	/// `nil` only until the width is measured.
	private var principalWidth: CGFloat? {
		guard topBarWidth > 0 else { return nil }
		return max(Self.minPrincipalWidth, topBarWidth - Self.principalSideReserve)
	}

	init() {
		Backports.Appearance.textField()
	}

	@ToolbarContentBuilder
	var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .principal) {
			// iPad/Mac group BACK | ADDRESS | FORWARD | RELOAD together; iPhone shows only
			// the address here and relies on the floating capsule for navigation.
			HStack(spacing: 8) {
				if showsTopBarNavigation {
					WebBackButton()
				}
				// On iPhone portrait the address moves to the bottom bar (AIA-0338); the
				// top bar then keeps only cpu / Find / detection / edit.
				if bottomAddressBarActive == false {
					WebAddressDisplay(
						onEdit: { locationSheet = .edit },
						onClear: { locationSheet = .compose },
						// iPhone-landscape top bar gets the clear ✕; iPad/Mac top bar is unchanged.
						showsClear: HostPlatform.current.isiPhone
					)
				}
				if showsTopBarNavigation {
					WebForwardButton()
					WebReloadStopButton()
				}
			}
			.environmentObject(appState.browserState)
			// Gap to the neighboring cpu / detection toolbar buttons. The explicit footprint
			// forces the stretch the `.principal` placement won't give on any idiom; the
			// address inside fills it. principalWidth is nil only until the width is measured.
			.padding(.horizontal, principalWidth == nil ? 0 : Self.principalGap)
			.frame(width: principalWidth)
		}
	}

    var body: some View {
        // DetectableView handles both snapshotting and annotation in one coordinated scope
        // This keeps detection state local to WebScreenView and ensures coordinate alignment
        DetectableView(
			snapshotWorkCoordinator: appState.snapshotWorkCoordinator,
            drivers: appState.deep.drivers,
			soundPlayer: appState.annotationSoundPlayer,
            trigger: appState.snap.combinedPublishers,
            showIdentifiers: showIdentifiers,
            animateDetections: animateDetections,
            tiling: tiling,
            tiledBorders: tiledBorders,
            detectionActive: detectionActive,
			acceptsSnapshot: { appState.detectionState.accepts($0) },
			contentGeometryDidChange: { appState.detectionState.contentGeometryDidChange() },
			contentInteractionDidEnd: { appState.detectionState.contentInteractionDidEnd() },
            isCapturingFinding: $isCapturingFinding,
            onFrameChanged: { frame in
                appliedFrame = frame
            },
            onInteractionStateChanged: { state in
                // Optionally propagate to chromeState for other UI components to observe
                appState.chromeState.contentInteractionState = state
				// A resolver asks the live page for its coordinate. If the user moves the page after
				// tapping the aligned crosshair but before that answer arrives, drop the stale frame
				// and stay in alignment mode, so the crosshair goes back to red until the page
				// settles and a current detection covers the centre again.
				if state.isInteracting && isResolvingCapture {
					abandonPendingCapture()
				}
            }
        ) { interactionState in
			MLWebView(loadRequest, renderer: appState.webViewRenderer, rendererAttached: {
				appState.snapshotWorkCoordinator.rendererDidAttach()
			}, loadStatusChanged: { loading, error in
				LoggingPolicy.debug("WebView loading status changed: \(loading ? "loading" : "loaded")", logger: .ui)
                if let error = error {
					switch webViewLoadErrorLevel(for: error) {
					case .debug:
						// Benign cancellation (load superseded by navigating away / reload /
						// redirect). Downgraded so it stops being captured as a Sentry error
						// (AIA-0296) — genuine load failures still log at .error below.
						LoggingPolicy.debug("WebView loading cancelled: \(error.localizedDescription)", logger: .ui)
					case .error:
						// The URL out of the ERROR, not out of the address bar. `displayedURL` is
						// mutable and deliberately keeps the previous page until a commit, so a failed
						// search reported the site the user was on before it — and a superseded
						// navigation failing late reported the newer one (raised in review). WebKit
						// names the failing URL in the error itself; nothing else is attributable, so
						// when it is absent no address is sent at all.
						let page = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
						LoggingPolicy.error(
							"WebView loading error [site: \(page?.host ?? "unknown")]: \(error.localizedDescription)",
							page: page,
							logger: .ui
						)
					}
                }
            }, interactionStateChanged: { state in
                // Update DetectableView's internal state via binding
                interactionState.wrappedValue = state
            })
            .equatable()
            // AIA-0509: a changed identity rebuilds the underlying WKWebView, which is the only
            // recovery available when the renderer itself is wedged rather than the navigation.
            .id(webViewGeneration)
        }
        .onReceive(appState.settings.$showIdentifiers) { value in
            showIdentifiers = value
        }
        .onReceive(appState.settings.$disableDetectionAnimations) { value in
            animateDetections = !value
        }
        .onReceive(appState.settings.$pyramidTiling) { _ in
            tiling = appState.settings.tilingSchemes
        }
        .onReceive(appState.settings.$grid3x3Tiling) { _ in
            tiling = appState.settings.tilingSchemes
        }
        .onReceive(appState.settings.$tiledBorders) { value in
            tiledBorders = value
        }
        .onReceive(appState.detectionState.$ontheflyDetectionEnabled) { value in
            detectionActive = value
        }
        .onReceive(appState.deep.drivers.$classificators) { classificators in
            fireImmediateSnapshotIfDriverAdded(Set(classificators.map(\.id)), previous: $runningClassifierIDs)
        }
        .onReceive(appState.deep.drivers.$detectors) { detectors in
            fireImmediateSnapshotIfDriverAdded(Set(detectors.map(\.id)), previous: $runningDetectorIDs)
        }
        .onAppear {
            showIdentifiers = appState.settings.showIdentifiers
            animateDetections = !appState.settings.disableDetectionAnimations
            tiling = appState.settings.tilingSchemes
            tiledBorders = appState.settings.tiledBorders
            if hasPerformedInitialAction.not {
                hasPerformedInitialAction = true
                if appState.chromeState.pageToOpen != nil {
                    // A shared link is already waiting; the `onReceive` above loads it. Skipping the
                    // default here is what stops a home-page flash when `onAppear` wins the race —
                    // the flag set above covers the other ordering.
                    intendedPageKind = "sharedLink"
                } else if let fixtureURL = appState.settings.launchFixtureURL {
                    // AIA-0316 UI-test harness: load a bundled local-HTML fixture directly via
                    // loadFileURL. Highest precedence, and deliberately NOT recorded in history.
                    intendedPageKind = "localFixture"
                    if loadRequest.fileURL != fixtureURL {
                        loadRequest = loadRequest.nextFile(fixtureURL)
                    }
                } else if let onboardingPage = appState.settings.onboardingInitialPage?.absoluteString {
                    // First-launch onboarding (AIA-0333): load the demo page the tour points at,
                    // taking precedence over the home page. Set deterministically before the UI
                    // appears, so it never races the default-page load.
                    intendedPageKind = "onboarding"
                    if loadRequest.input != onboardingPage {
                        loadRequest = loadRequest.next(onboardingPage)
                    }
                    createOrRefreshWebHistoryEntry(onboardingPage, maxEntries: appState.settings.historySize)
                    // One-shot: clear it so a later WebScreen re-creation (tab/mode switch) doesn't
                    // re-force the onboarding page over the user's real home/last page.
                    appState.settings.onboardingInitialPage = nil
                } else if
                    appState.settings.reopenLastPage.enabled,
                    let lastPage = appState.settings.lastPage {
                    intendedPageKind = "last"
                    // Not a user load: the display gate stays open and KVO fills the bar.
                    if loadRequest.input != lastPage.absoluteString {
                        loadRequest = loadRequest.next(lastPage.absoluteString)
                    }
                } else if let defaultPage = appState.settings.defaultPage?.absoluteString,
                    defaultPage.lowercased() != "about:blank" {
                    intendedPageKind = "home"
                    // No generation bump when the initial request already targets the
                    // default page — it would reload the same URL a second time.
                    if loadRequest.input != defaultPage {
                        loadRequest = loadRequest.next(defaultPage)
                    }
                    createOrRefreshWebHistoryEntry(defaultPage, maxEntries: appState.settings.historySize)
                } else {
                    // No home page, or an explicit about:blank — stay blank rather than
                    // search-treating "about:blank" in the load pipeline (AIA-0298).
                    intendedPageKind = "blank"
                }
            }
        }
        .checkpoint(.intendedPageKind, value: intendedPageKind)
        // Mirror the live URL's file name into a @State so the checkpoint re-renders on every
        // navigation (WebScreenView observes appState, not browserState directly). The `\.url` KVO
        // path fires for host-less file:// URLs too, so this reflects local fixtures (AIA-0316).
        // Gated on `isRunningUITests`: this is UI-test-only introspection, so it must not write
        // @State (and trigger re-renders) on every URL change during normal browsing (e.g. SPAs).
        .onReceive(appState.browserState.$currentURL) { url in
            guard AppEnvironment.isRunningUITests else { return }
            currentPageFile = url?.lastPathComponent ?? ""
        }
        .checkpoint(.currentPageFile, value: currentPageFile)
        // Surfaces whether detection has applied a frame yet, so UI tests can wait for it before a
        // manual finding pick (which uses the applied frame synchronously, avoiding the fragile
        // fresh-snapshot fallback) — AIA-0333.
        .checkpoint(.detectionFrameApplied, value: (appliedFrame != nil).description)
        .sheet(item: $locationSheet) { mode in
            LocationSheetView(currentURL: mode == .edit ? appState.browserState.displayedURL?.absoluteString : nil) { input in
                openRequested(input)
            }
            .environmentObject(appState.settings)
        }
        .sheet(item: $findingCapture, onDismiss: {
            // Every dismissal path (Save, Cancel, interactive swipe) ends the
            // capture: unfreeze the displayed frame, then resume the timer —
            // its immediate snapshot replaces the frozen frame right away.
            isCapturingFinding = false
			appState.snapshotWorkCoordinator.findingCaptureEnded()
            appState.detectionState.findingCaptureEnded()
            // Tour (AIA-0333): a dismiss without a save returns to the capture step (no-op once
            // the finding was saved, which already advanced the step).
            appState.tour.captureCancelled()
            // AIA-0117: a cancel recorded no moment, so this is a no-op on that path.
            let saved = didSaveFinding
            didSaveFinding = false
            if appState.reviewPrompt.consumePendingRequest(.findingSaved, isTourActive: appState.tour.isActive) {
                requestReview()
            } else if saved {
                // Only when the review prompt stayed quiet: two modals racing one dismissal is a
                // bug, and the review moment is the older claim on it (AIA-0117/0536).
                offerSignInIfEarned()
            }
        }) { capture in
            SaveFindingSheet(
                capture: capture,
                tour: appState.tour,
                repository: appState.findingRepository,
                reviewPrompt: appState.reviewPrompt,
                defaultAuthor: appState.authState.accountDisplayName,
                onSaved: { didSaveFinding = true }
            )
            // The form-sheet default left the cropped preview as a strip, with the address wrapping
            // to three lines above it (reported from a build on iPad).
            .roomySheet()
        }
        .sheet(isPresented: $showSignInOffer) {
            SignInSheet(authState: appState.authState)
                // Re-inject across the sheet boundary (AGENTS.md §3).
                .environment(\.usesRealAuth, usesRealAuth)
        }
        .onReceive(appState.chromeState.$pageToOpen) { url in
            // A finding's "open page" action lands here (the findings UI cannot
            // reach the web view directly).
            guard let url else { return }
            // A shared link IS this screen's initial action, so claim it. `.onAppear` below performs
            // the default first load (onboarding / last page / home) and there is no guaranteed
            // ordering between the two: on a FIRST mount — a link opened from behind the paywall,
            // which is the whole point of AIA-0657 — `onAppear` ran second and overwrote the page
            // the user had asked for with the home page. Reported from a real build; no unit test
            // reaches a SwiftUI lifecycle race.
            hasPerformedInitialAction = true
            // Cleared on the NEXT runloop turn, not inline, and that is not a style choice.
            // `@Published` publishes from `willSet`, so this closure runs *inside* the assignment
            // that delivered the value — the inline `pageToOpen = nil` completed first and the
            // outer assignment then wrote the URL back over it, leaving the latch permanently
            // armed. Nothing failed visibly: the page loaded, and the next time this screen was
            // rebuilt (a tab or mode switch) the stale value was redelivered and navigated away
            // from whatever the user was reading. Measured on develop before AIA-0657.
            // `SharedFindingStateTests` pins the Combine semantics that force this shape, but it
            // cannot reach a SwiftUI `onReceive` closure — so nothing automated fails if this line
            // reverts to an inline assignment. Stated rather than implied.
            DispatchQueue.main.async { appState.chromeState.pageToOpen = nil }
            openRequested(url.absoluteString)
        }
        .onReceive(appState.chromeState.$findModeRequested) { requested in
            guard requested else { return }
            appState.chromeState.findModeRequested = false
			// Find is still reachable while the overlay is up. Re-entering would freeze a second
			// time with no matching end, and during the tour would re-take a freeze it already holds.
			guard findPickActive == false else { return }
			if appState.tour.isActive {
				// The published onboarding lesson still teaches its original one-tap map capture. It is
				// intentionally kept out of alignment mode (and therefore never shows the large
				// crosshair); changing that guided flow needs its own scripted map fixture and lesson.
				appState.snapshotWorkCoordinator.findingCaptureStarted()
				isCapturingFinding = true
				appState.detectionState.findingCaptureStarted()
			}
            // This is not a capture yet. Keeping the normal interaction lifecycle alive is what
            // lets WKWebView receive pan/pinch gestures and refreshes boxes after it settles.
            findPickActive = true
        }
        .overlay {
            if findPickActive {
                FindPickOverlay(
                    results: appliedFrame?.results ?? [],
                    isAligned: alignedDetection != nil,
                    allowsTourManualPick: appState.tour.isActive,
                    onPick: pickForTour,
                    onCapture: captureUnderCrosshair,
                    onCancel: cancelFindPick
                )
            }
        }
        // AIA-0509: the page failed to load and automatic recovery is exhausted. Attached as an
        // overlay (like FindPickOverlay above) rather than inside DetectableView's content
        // builder, so it sits above the annotation layers and blocks interaction with them —
        // the builder's content renders inside SnapableGroup's GeometryReader, below them.
        .overlay {
            if let failure = loadFailure {
                WebLoadFailureOverlay(failure: failure) {
                    appState.browserState.retryRequested()
                }
            }
        }
        .onReceive(appState.browserState.$loadFailure) { failure in
            loadFailure = failure
            // The recovery ladder is exhausted and the failure UI is up, so a run interrupted by the
            // termination has nothing to come back to. Read from `BrowserState` rather than from the
            // raw delegate error: this verdict is already filtered for the current web view and
            // ignores the cancellations that are the ordinary result of navigating away, which the
            // delegate callback is not (raised in review).
            if failure != nil {
                appState.detectionState.webContentDidFailToLoad()
            }
        }
        // Deliberately NOT `dropFirst()`. `@Published` replays its current value to every new
        // subscriber and SwiftUI resubscribes whenever it remounts this screen, so dropping the first
        // delivery loses a termination that happened while this screen was unmounted — and during a
        // transition the outgoing and incoming subscriptions can both receive the same live change,
        // which dropping cannot prevent either. The generation is consumed in `DetectionSessionState`
        // instead, which outlives the view and can tell a repeat from a redelivery (AIA-0879).
        // One publisher, not two. `@Published` replays its current value to every new subscriber and
        // SwiftUI resubscribes whenever it remounts this screen, so two of them would replay
        // INDEPENDENTLY — a termination from while the screen was unmounted and the recovery that
        // settled after it, in whichever order these modifiers happened to be written. That order
        // decided whether detection came back or stayed paused forever (raised in review). One value
        // replays once, and it is the latest, which is all a remounting observer needs.
        //
        // Not `dropFirst()`: that would discard an event published while this screen was unmounted.
        // The sequence is consumed in `DetectionSessionState`, which outlives the view.
        .onReceive(appState.browserState.$webContentEvent) { event in
            switch event.kind {
            case .none:
                break
            case let .processTerminated(host):
                appState.detectionState.webContentProcessDidTerminate(
                    sequence: event.sequence,
                    host: host
                )
            case .loaded:
                appState.detectionState.webContentDidLoad(sequence: event.sequence)
            case .stopped:
                appState.detectionState.webContentDidStopLoading(sequence: event.sequence)
            }
        }
        .onReceive(appState.browserState.$rebuildRequest) { request in
            guard let request else { return }
            // A rebuild mid-capture yanks the web view out from under a frozen frame: the
            // renderer holds it weakly, so `snapshot()` starts returning nil and the pick is
            // silently cancelled. Both states are user-driven and brief, so skip the rebuild and
            // leave the failure overlay standing — Try Again is available once the capture ends.
            guard isCapturingFinding == false, findPickActive == false else {
                appState.browserState.rebuildRequestDeclined()
                return
            }
            // Point the request at where the user actually is, with caching bypassed: the fresh
            // Coordinator has no `lastLoadedGeneration`, so it loads whatever `loadRequest` holds
            // — without this it would reload the original `.onAppear` page instead.
            loadRequest = loadRequest.next(
                request.url.absoluteString,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            // Clears the display gate before the web view that owns its navigation token is
            // destroyed; otherwise the address bar freezes for the rest of the session.
            appState.browserState.webViewInvalidated()
            webViewGeneration = request.generation
            appState.browserState.rebuildRequestHandled()
        }
        .onDisappear {
            // The screen can be unmounted mid-capture (mode switch): without
            // this, the snap timer would stay paused and the pick/sheet state
            // would leak into the next appearance.
            guard findPickActive || isCapturingFinding || findingCapture != nil else { return }
            findingCapture = nil
            cancelFindPick()
        }
        .alert(isPresented: $showAlert) {
            alertForError(latestError)
        }
        .environmentObject(appState.browserState)
        .navigationBarTitle("", displayMode: .inline)
        .clipped()
        // The content area spans the navigation bar width; capture it to size the address bar,
        // since the `.principal` item won't stretch on iPhone. Updates on rotation.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { topBarWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in topBarWidth = newWidth }
            }
        }
        // Adaptive address bar (AIA-0338): in iPhone portrait the address sits at the
        // bottom, above the home indicator. `safeAreaInset` reserves the space so the web
        // content is pushed up rather than covered (content respects the safe area in
        // normal mode — `contentIgnoresSafeArea` is fullscreen-only). The floating nav
        // capsule is lifted clear of this bar via its `bottomReserve` in ContentView.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomAddressBar
        }
        .toolbar {
            toolbarContent
        }
    }

    /// The bottom placement of the address bar (iPhone portrait). Empty otherwise, so the
    /// inset reserves no space. Reuses the same `WebAddressDisplay` (one id, one sheet
    /// trigger) as the `.principal` placement.
    @ViewBuilder
    private var bottomAddressBar: some View {
        if bottomAddressBarActive {
            WebAddressDisplay(
                onEdit: { locationSheet = .edit },
                onClear: { locationSheet = .compose },
                // Bottom bar is iPhone-portrait only, so the clear ✕ is always shown here.
                showsClear: HostPlatform.current.isiPhone
            )
            .environmentObject(appState.browserState)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: BottomAddressBarMetrics.height)
            // No opaque background strip: the glass capsule floats over the page like Safari's
            // (the inset still reserves the space above the home indicator).
        }
    }

	/// Fires one immediate snapshot when a driver newly appears in a bucket, so a model enabled
	/// mid-session runs on the current page at once instead of waiting for the next timer tick or a
	/// scroll. The detection-session owner gates the request on its authoritative active state and
	/// preserves the run identifier, so a late result can never cross a pause/restart boundary.
	private func fireImmediateSnapshotIfDriverAdded(_ current: Set<UUID>, previous: Binding<Set<UUID>>) {
		let added = current.subtracting(previous.wrappedValue)
		previous.wrappedValue = current
		guard added.isEmpty == false else { return }
		appState.detectionState.driverDidRegister()
	}

	/// A displayed detection is selected when it truly covers the stationary centre crosshair.
	/// The smallest nested rectangle wins, matching the existing direct-pick rule.
	private var alignedDetection: (observation: DetectedObject, params: DeepDriverParams)? {
		guard findPickActive, appState.tour.isActive.not,
			appState.chromeState.contentInteractionState.isInteracting.not,
			let appliedFrame
		else { return nil }
		return FindingCapture.detectionAlignedWithCentre(in: appliedFrame.results)
	}

	/// The crosshair was tapped. Green stores the detection that covers it; red stores the centre
	/// itself as a manual observation, because plenty of what a user wants to record is something
	/// no enabled model detects (owner request). The colour therefore says what *kind* of finding
	/// the tap will make, not whether the tap does anything.
	///
	/// Detection stays live for the whole aiming phase — that is what lets the boxes follow the
	/// page the user is panning — so the freeze happens only here, pinning the exact frame that
	/// was on screen while the location resolver runs.
	///
	/// Alignment is re-read from the frame current at the moment of the tap rather than from
	/// whatever made the crosshair green a moment earlier: a newer detection pass can land between
	/// the render and the touch, and a capture must come from the frame it will save.
	private func captureUnderCrosshair(in size: CGSize) {
		guard findPickActive, isResolvingCapture.not else { return }
		if let hit = alignedDetection, let frame = appliedFrame {
			beginCapture()
			presentResolvingLocation(
				observation: hit.observation,
				params: hit.params,
				frame: frame,
				generation: captureResolutionGeneration
			)
			return
		}
		captureCentreManually(in: size)
	}

	/// Nothing is aligned: store the crosshair's own position as a synthetic observation with no
	/// class, confidence or driver — the same shape the pre-AIA-0868 tap-anywhere pick produced,
	/// anchored at the centre instead of at an arbitrary touch.
	///
	/// The displayed frame is reused when detection is running, so the saved image is the one whose
	/// boxes the user was looking at. With detection off there is no frame at all and a snapshot is
	/// taken here — the branch that makes "record a place the models say nothing about" work.
	private func captureCentreManually(in size: CGSize) {
		let observation = DetectedObject(
			uuid: UUID(),
			labels: [],
			confidence: 0,
			boundingBox: FindingCapture.manualBox(
				at: CGPoint(x: size.width / 2, y: size.height / 2),
				in: size
			),
			regionIndex: 0
		)
		beginCapture()
		if let frame = appliedFrame {
			presentResolvingLocation(
				observation: observation,
				params: nil,
				frame: frame,
				generation: captureResolutionGeneration
			)
			return
		}
		let generation = captureResolutionGeneration
		Task { @MainActor in
			defer {
				if captureResolutionGeneration == generation {
					isResolvingCapture = false
				}
			}
			LoggingPolicy.info("Manual finding capture: taking web snapshot", logger: .ui)
			// Resolved BEFORE the snapshot await: the page can navigate while a snapshot is being
			// taken, and the finding must record the page these pixels came from rather than
			// whatever the web view moved on to.
			let resolved = await appState.browserState.resolveCaptureLocation()
			let image = await appState.webViewRenderer.snapshot()
			// Checked BEFORE acting on the failure, not only before presenting: this task may have
			// been superseded while it waited (the user moved the page, then tapped again). A stale
			// task that called `cancelFindPick()` would tear down the *current* attempt — dropping
			// the user out of alignment mode, or unfreezing the frame under a sheet the newer
			// attempt had already presented.
			guard captureResolutionGeneration == generation, findPickActive else { return }
			guard let image else {
				// WebSnapshotRenderer records the concrete WebKit error when one is available.
				// Cancelling here is the expected fallback for a frame that cannot be snapshotted,
				// so keep it as a breadcrumb instead of sending a second, context-free Sentry error.
				LoggingPolicy.warning("Manual finding capture cancelled: snapshot unavailable", logger: .ui)
				cancelFindPick()
				return
			}
			present(FindingCapture(
				observation: observation,
				params: nil,
				frame: AppliedDetectionFrame(image: image, results: []),
				location: resolved
			))
		}
	}

	/// Freezes the displayed frame and opens a new resolution generation. Every capture path goes
	/// through this so the freeze and the generation bump cannot drift apart.
	private func beginCapture() {
		isResolvingCapture = true
		captureResolutionGeneration &+= 1
		appState.snapshotWorkCoordinator.findingCaptureStarted()
		isCapturingFinding = true
		appState.detectionState.findingCaptureStarted()
	}

	/// Drops an in-flight capture without leaving alignment mode: the frozen frame is released and
	/// detection resumes, so the crosshair returns to red and can go green again on a fresh frame.
	/// Distinct from ``cancelFindPick()``, which is the user's explicit exit.
	private func abandonPendingCapture() {
		captureResolutionGeneration &+= 1
		isResolvingCapture = false
		guard isCapturingFinding else { return }
		isCapturingFinding = false
		// Dropped here as well as by the coordinator's own interaction clear. That clear reads the
		// freeze flag through a Binding written one line above, and this screen must not depend on
		// that write being visible within the same event: a frame that outlived its freeze is the
		// pre-movement page, and reusing it would turn the crosshair green over boxes that have
		// moved away, or save an image that is no longer what the user is looking at.
		appliedFrame = nil
		appState.snapshotWorkCoordinator.findingCaptureEnded()
		appState.detectionState.findingCaptureEnded()
	}

	/// Offer sign-in once, after a save, to someone who could actually act on it.
	///
	/// Deliberately narrow. The offer is a convenience, not a gate: the save already succeeded and
	/// nothing about it depends on an account. So it is skipped during onboarding, for anyone not
	/// plainly signed out, and after it has been shown once — with the marker set here, at the moment
	/// of showing, so a save that produced no offer never spends the single chance to ask.
	private func offerSignInIfEarned() {
		guard case .anonymous = appState.authState.effectiveContext else { return }
		guard !appState.tour.isActive else { return }
		guard !appState.settings.signInOfferShown else { return }
		appState.settings.signInOfferShown = true
		showSignInOffer = true
	}

	/// Resolves the page's URL and, where a map will say, its coordinate — then presents the sheet
	/// (AIA-0817). Its caller has already frozen the aligned snapshot.
	///
	/// Asking the live map is asynchronous, so the alignment overlay remains visible until
	/// `present`. If interaction resumes before that answer arrives, its generation is invalidated
	/// and this task returns without presenting a stale capture.
	private func presentResolvingLocation(
		observation: DetectedObject,
		params: DeepDriverParams?,
		frame: AppliedDetectionFrame,
		generation: UInt64
	) {
		Task { @MainActor in
			defer {
				if captureResolutionGeneration == generation {
					isResolvingCapture = false
				}
			}
			let resolved = await appState.browserState.resolveCaptureLocation()
			// The screen can be unmounted mid-resolve — a mode switch, or the user simply leaving —
			// and `onDisappear` cancels the pick. Without this the sheet would arrive afterwards, on
			// a screen the user had already walked away from (raised in review). `present` clears
			// the flag itself, so this reads it while it still means "the pick is live".
			guard captureResolutionGeneration == generation, findPickActive else { return }
			present(FindingCapture(
				observation: observation,
				params: params,
				frame: frame,
				location: resolved
			))
		}
	}

	/// The onboarding tour's established scripted map lesson remains a one-tap capture until that
	/// lesson can teach alignment against a deterministic detected rectangle. Production Find never
	/// installs this gesture: its large crosshair is inert and leaves all web-content gestures live.
	private func pickForTour(at location: CGPoint, in size: CGSize) {
		guard findPickActive, isResolvingCapture.not, let frame = appliedFrame else { return }
		let selection = FindingCapture.detection(at: location, in: size, results: frame.results)
		let observation = selection?.observation ?? DetectedObject(
			uuid: UUID(),
			labels: [],
			confidence: 0,
			boundingBox: FindingCapture.manualBox(at: location, in: size),
			regionIndex: 0
		)
		isResolvingCapture = true
		captureResolutionGeneration &+= 1
		presentResolvingLocation(
			observation: observation,
			params: selection?.params,
			frame: frame,
			generation: captureResolutionGeneration
		)
	}

	/// Alignment mode ends only when the capture is ready (or cancelled).
	private func present(_ capture: FindingCapture) {
		findPickActive = false
		findingCapture = capture
	}

	/// Leaves pick mode without storing: unfreeze and resume (the sheet path
	/// does the same via its onDismiss).
	private func cancelFindPick() {
		findPickActive = false
		// Releases the freeze only if one was actually taken: alignment mode leaves detection
		// running until the crosshair is tapped, so a cancel from the red state has nothing to end.
		abandonPendingCapture()
	}

	/// The location sheet confirmed an input (Open button, return key, or history pick).
	private func openRequested(_ input: String) {
		guard input.browserInputType != .unusable else { return }
		appState.browserState.userLoadRequested(input)
		loadRequest = loadRequest.next(input)
		guard input.browserInputType == .url else { return }
		createOrRefreshWebHistoryEntry(input, maxEntries: appState.settings.historySize)
	}

	private func alertForError(_ error: HistoryError?) -> Alert {
		switch error {
		case .fullHistory:
			return localizedAlert(
				title: L10n.Alert.Warning.title,
				message: L10n.Alert.History.Full.message,
				primaryButton: .default(Text(L10n.Common.ok))
			)
		case .none:
			return Alert(title: Text(""))
		}
	}

	/// Records the URL at the moment it is entered in the address bar — deliberately
	/// before the page loads (a never-finishing page still belongs to the history).
	/// Re-entering an existing URL refreshes its timestamp instead of being skipped,
	/// so the Recent ordering in the location sheet reflects actual use.
	private func createOrRefreshWebHistoryEntry(_ urlString: String, maxEntries: Int) {
		// Entries are stored with the https-normalized URL, so compare the same form.
		if let existing = history.first(where: { $0.page?.absoluteString == urlString.withHTTPS }) {
			existing.creationDate_ = .now
			existing.visitCount += 1
			do {
				try WebHistoryEntry.save(in: moc)
			} catch {
				LoggingPolicy.error("Failed to refresh web history entry timestamp", error: error, logger: .state)
			}
			return
		}

		// Use existing @FetchRequest count instead of fetching all objects
		guard history.count < maxEntries else {
			latestError = HistoryError.fullHistory
			showAlert = true
			return
		}

		let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: moc)
		newHistorEntry.bookmarked = false
		newHistorEntry.creationDate_ = .now
		newHistorEntry.visitCount = 1
		// Use the function parameter — the same value the duplicate check above compared.
		newHistorEntry.page = URL(string: urlString.withHTTPS)
		// Lifecycle: transition to draft before validation, then to ready if valid
		// If validation fails, the entity is deleted (brief inconsistent state is acceptable)
		newHistorEntry.transition(to: .draft)
		do {
			try newHistorEntry.validateForInsert()
			newHistorEntry.transition(to: .ready)
		} catch {
			WebHistoryEntry.delete(newHistorEntry, in: moc)
			LoggingPolicy.error("Web history entry validation failed: \(error.localizedDescription)", logger: .state)
			return
		}
		do {
			try WebHistoryEntry.save(in: moc)
		} catch {
			LoggingPolicy.error("Failed to save web history entry", error: error, logger: .state)
		}
	}
}

// MARK: - Find pick overlay

/// The visual half of finding alignment. It deliberately contains no full-screen hit-testable
/// background: pan and pinch events must continue to the live WKWebView below, because panning the
/// page under a stationary target IS the interaction. The interactive parts are Cancel and the
/// crosshair's small centre core.
private struct FindPickOverlay: View {
	/// Point size of the crosshair glyph in the hint capsule. The centre target is defined as
	/// exactly four times this, per the ticket, instead of an independently tuned constant.
	static let hintSymbolPointSize: CGFloat = 17

	let results: [DetectionResult]
	let isAligned: Bool
	/// The onboarding lesson retains its existing one-tap map exercise. It never draws the large
	/// crosshair, so alignment mode's gesture pass-through promise remains unambiguous.
	let allowsTourManualPick: Bool
	let onPick: (CGPoint, CGSize) -> Void
	let onCapture: (CGSize) -> Void
	let onCancel: () -> Void

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .top) {
				if allowsTourManualPick {
					Color.black.opacity(0.15)
						.contentShape(Rectangle())
						.gesture(SpatialTapGesture().onEnded { value in
							onPick(value.location, geometry.size)
						})
				} else {
					FindingAlignmentCrosshair(isAligned: isAligned) { onCapture(geometry.size) }
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
				detectionBoxes(in: geometry.size)
				hint
			}
		}
	}

	@ViewBuilder
	private func detectionBoxes(in size: CGSize) -> some View {
		ForEach(Array(results.enumerated()), id: \.offset) { _, group in
			ForEach(group.observations, id: \.uuid) { observation in
				let rect = observation.boundingBox.visionRect(in: size)
				Rectangle()
					.stroke(group.params.annotationColor, lineWidth: 3)
					.frame(width: rect.width, height: rect.height)
					.position(x: rect.midX, y: rect.midY)
					.allowsHitTesting(false)
			}
		}
	}

	/// The tour keeps the original one-tap wording; alignment mode names the move to make, then the
	/// action that becomes available once the crosshair is green.
	private var hintText: String {
		if allowsTourManualPick { return L10n.Finding.Pick.hint }
		return isAligned ? L10n.Finding.Pick.aligned : L10n.Finding.Pick.align
	}

	private var hint: some View {
		HStack(spacing: 12) {
			Image(systemName: "plus.viewfinder")
				.font(.system(size: Self.hintSymbolPointSize))
			Text(hintText)
			Button(L10n.Common.cancel, action: onCancel)
				.bold()
				.testability(Testability.Button.findPickCancel)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.background(.regularMaterial, in: Capsule())
		.padding(.top, 12)
		.frame(maxWidth: .infinity)
	}
}

/// The hint capsule's crosshair, four times as wide and four times as tall, at the centre of the
/// web content. It pulses red while no detected rectangle covers that centre and green once one
/// does, and a tap stores a finding either way: the colour says which kind, not whether the tap
/// works.
///
/// Only a 44-point core accepts that tap. The drawn glyph is far larger, but a glyph-sized touch
/// area would swallow pans that start near the target — and panning the page under the target is
/// the whole interaction. The core is the standard minimum control size, so the compromise costs a
/// fingertip in the middle of the screen and leaves the rest of the content pannable.
private struct FindingAlignmentCrosshair: View {
	let isAligned: Bool
	let onCapture: () -> Void
	@State private var pulseExpanded = false

	/// Four times the capsule glyph in both directions. `Image` scales a symbol by its point size,
	/// which sets width and height together, so one multiplier expresses both halves of the rule.
	private static let pointSize = FindPickOverlay.hintSymbolPointSize * 4
	private static let tapCoreSide: CGFloat = 44

	var body: some View {
		Image(systemName: "plus.viewfinder")
			.font(.system(size: Self.pointSize, weight: .regular))
			.symbolRenderingMode(.hierarchical)
			.foregroundStyle(isAligned ? Color.green : Color.red)
			.scaleEffect(pulseExpanded ? 1.08 : 0.92)
			.opacity(pulseExpanded ? 1 : 0.68)
			.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseExpanded)
			.onAppear { pulseExpanded = true }
			// The glyph itself never takes touches. Applied before the overlay so the pulse, which
			// animates `scaleEffect`, cannot breathe the tap area in and out with it.
			.allowsHitTesting(false)
			.overlay { tapCore }
	}

	private var tapCore: some View {
		Color.clear
			.frame(width: Self.tapCoreSide, height: Self.tapCoreSide)
			.contentShape(Circle())
			.onTapGesture(perform: onCapture)
			.accessibilityElement()
			.accessibilityLabel(isAligned ? L10n.Finding.Pick.aligned : L10n.Finding.Pick.align)
			.accessibilityAddTraits(.isButton)
			.testability(Testability.View.findingAlignmentCrosshair)
	}
}

// MARK: - Browser chrome components

/// Layout constants shared by the bottom address bar (AIA-0338) and the floating-control
/// reserve. One source so the bar's height and the capsule lift can't drift apart.
enum BottomAddressBarMetrics {
	/// Pinned height of the bottom bar (single-line, truncating). Pinned so Dynamic Type
	/// can't change it and silently invalidate `reserve`.
	static let height: CGFloat = 44
	/// Gap kept between the bottom bar and the floating controls above it.
	static let gap: CGFloat = 8
	/// Vertical space the floating nav capsule / chrome button reserve from the bottom
	/// edge while the bar is shown. = height + gap; the floats already sit a margin above
	/// the screen bottom, so this guarantees clearance (extra margin is harmless) and is
	/// enforced by a UI frame-ordering test (`bar.minY > capsule.maxY`).
	static let reserve: CGFloat = height + gap
}

/// Read-only URL display; tapping the text presents the location sheet for editing, while the
/// trailing clear (✕) — shown on iPhone when there's a URL — opens the sheet blank to compose a
/// fresh one. The clear affordance is part of the iPhone adaptive-bar work (AIA-0338); iPad/Mac
/// keep their unchanged top bar, so callers there pass `showsClear: false`.
private struct WebAddressDisplay: View {
	@EnvironmentObject var browserState: BrowserState
	/// Tapping the URL text — opens the location sheet prefilled with the current URL.
	let onEdit: () -> Void
	/// Tapping the trailing clear (✕) — opens the location sheet blank to compose a fresh URL.
	let onClear: () -> Void
	/// Whether to show the trailing clear (✕). iPhone-only (both portrait-bottom and
	/// landscape-top placements); off on iPad/Mac so their top bar is unchanged (AIA-0338).
	let showsClear: Bool

	var body: some View {
		let hasURL = browserState.displayedURL != nil
		let urlText = browserState.displayedURL?.absoluteString ?? L10n.Browser.Location.placeholder
		let textColor: Color = hasURL ? .primary : .secondary
		// Padding lives inside each button's label (not on the HStack) so the whole visible
		// capsule — including its padded edges and rounded ends — is a live tap target, not
		// just the text's bounds (AIA-0338).
		HStack(spacing: 0) {
			Button(action: onEdit) {
				Text(urlText)
					.lineLimit(1)
					.truncationMode(.middle)
					.foregroundColor(textColor)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 7)
					.padding(.leading, 14)
					.padding(.trailing, hasURL ? 6 : 14)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			// VoiceOver reads the actual URL, not just the affordance.
			.accessibilityLabel(urlText)
			.testability(Testability.Button.webScreenAddressBar)
			.tourTarget(.addressBar)

			if hasURL && showsClear {
				Button(action: onClear) {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
						.padding(.vertical, 7)
						.padding(.trailing, 14)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel(L10n.Common.clear)
				.testability(Testability.Button.webScreenAddressClear)
			}
		}
		// Safari-like Liquid Glass capsule (iOS 26+); material-capsule fallback on earlier systems.
		.platformEffect(in: Capsule())
	}
}

private struct WebBackButton: View {
	@EnvironmentObject var browserState: BrowserState

	var body: some View {
		Button(action: {
			browserState.goBackTapped()
		}) {
			Image(systemName: "chevron.left")
				.foregroundColor(.gray)
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
		}
		.disabled(browserState.canGoBack.not)
		.accessibilityLabel(L10n.Browser.Navigation.back)
		.testability(Testability.Button.webToolbarBack)
	}
}

private struct WebForwardButton: View {
	@EnvironmentObject var browserState: BrowserState

	var body: some View {
		Button(action: {
			browserState.goForwardTapped()
		}) {
			Image(systemName: "chevron.right")
				.foregroundColor(.gray)
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
		}
		.disabled(browserState.canGoForward.not)
		.accessibilityLabel(L10n.Browser.Navigation.forward)
		.testability(Testability.Button.webToolbarForward)
	}
}

/// Reload/stop, part of the browser cluster around the address display (regular width
/// only — compact has the floating capsule). Lives in the principal group so it reads
/// as a browser action, not a detection one.
private struct WebReloadStopButton: View {
	@EnvironmentObject var browserState: BrowserState

	var body: some View {
		Button(action: {
			if browserState.isLoading {
				browserState.stopTapped()
			} else {
				browserState.reloadTapped()
			}
		}) {
			Image(systemName: browserState.isLoading ? "xmark" : "arrow.clockwise")
				.foregroundColor(.gray)
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
		}
		.accessibilityLabel(browserState.isLoading ? L10n.Browser.Navigation.stop : L10n.Browser.Navigation.reload)
		.testability(Testability.Button.webToolbarReload)
	}
}
