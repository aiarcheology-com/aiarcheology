//
//  WebScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI
import OSLog

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
	@State private var tiling: TilingScheme = []
	/// Mirrors the "Tiled Borders" setting (AIA-0426) into local state so DetectableView can draw the
	/// per-tile debug outlines. Available in all builds, toggled from the Tiled Detection submenu.
	@State private var tiledBorders: Bool = false
	/// Mirrors `guide.ontheflyDetectionEnabled` (play/pause) so DetectableView can
	/// clear the classification presentation the moment detection stops (AIA-0374).
	@State private var detectionActive: Bool = false
	/// The tapped detection being saved; non-nil presents the save sheet.
	@State private var findingCapture: FindingCapture?
	/// Freezes DetectableView's displayed frame while the save sheet is up.
	@State private var isCapturingFinding: Bool = false
	/// Pick mode (Find/Store button): the next tap on the content marks the
	/// place to store — independent of whether detection is running.
	@State private var findPickActive: Bool = false
	/// Mirror of DetectableView's displayed frame (updated on every apply/clear):
	/// pick mode hit-tests its boxes and reuses its snapshot.
	@State private var appliedFrame: AppliedDetectionFrame?
	/// Live width of the screen content area (== the navigation bar width). The `.principal`
	/// toolbar item collapses to its content width instead of filling on every idiom, so the
	/// principal cluster is sized explicitly from this (AIA-0294 follow-up). A proper custom
	/// top bar (`safeAreaInset`) is the real fix, tracked in AIA-0339; this is the stopgap.
	@State private var topBarWidth: CGFloat = 0

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
            renderer: appState.webViewRenderer,
            drivers: appState.deep.drivers,
            trigger: appState.snap.combinedPublishers,
            showIdentifiers: showIdentifiers,
            tiling: tiling,
            tiledBorders: tiledBorders,
            detectionActive: detectionActive,
            isCapturingFinding: $isCapturingFinding,
            onFrameChanged: { frame in
                appliedFrame = frame
            },
            onInteractionStateChanged: { state in
                // Optionally propagate to chromeState for other UI components to observe
                appState.chromeState.contentInteractionState = state
            }
        ) { interactionState in
            MLWebView(loadRequest, renderer: appState.webViewRenderer, loadStatusChanged: { loading, error in
				LoggingPolicy.debug("WebView loading status changed: \(loading ? "loading" : "loaded")", logger: .ui)
                if let error = error {
					switch webViewLoadErrorLevel(for: error) {
					case .debug:
						// Benign cancellation (load superseded by navigating away / reload /
						// redirect). Downgraded so it stops being captured as a Sentry error
						// (AIA-0296) — genuine load failures still log at .error below.
						LoggingPolicy.debug("WebView loading cancelled: \(error.localizedDescription)", logger: .ui)
					case .error:
						LoggingPolicy.error("WebView loading error: \(error.localizedDescription)", logger: .ui)
					}
                }
            }, interactionStateChanged: { state in
                // Update DetectableView's internal state via binding
                interactionState.wrappedValue = state
            })
            .equatable()
        }
        .onReceive(appState.settings.$showIdentifiers) { value in
            showIdentifiers = value
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
        .onAppear {
            showIdentifiers = appState.settings.showIdentifiers
            tiling = appState.settings.tilingSchemes
            tiledBorders = appState.settings.tiledBorders
            if hasPerformedInitialAction.not {
                hasPerformedInitialAction = true
                if let fixtureURL = appState.settings.launchFixtureURL {
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
            appState.detectionState.findingCaptureEnded()
            // Tour (AIA-0333): a dismiss without a save returns to the capture step (no-op once
            // the finding was saved, which already advanced the step).
            appState.tour.captureCancelled()
        }) { capture in
            SaveFindingSheet(capture: capture, tour: appState.tour, repository: appState.findingRepository)
        }
        .onReceive(appState.chromeState.$pageToOpen) { url in
            // A finding's "open page" action lands here (the findings UI cannot
            // reach the web view directly).
            guard let url else { return }
            appState.chromeState.pageToOpen = nil
            openRequested(url.absoluteString)
        }
        .onReceive(appState.chromeState.$findModeRequested) { requested in
            guard requested else { return }
            appState.chromeState.findModeRequested = false
            // Freeze exactly like an annotation tap would: detection passes pause
            // and the displayed frame holds while the user picks the place.
            isCapturingFinding = true
            appState.detectionState.findingCaptureStarted()
            findPickActive = true
        }
        .overlay {
            if findPickActive {
                FindPickOverlay(
                    results: appliedFrame?.results ?? [],
                    onPick: pick,
                    onCancel: cancelFindPick
                )
            }
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

	/// The user marked a place in pick mode — the ONLY capture path (direct taps on
	/// annotations would clash with the web app's own gestures, like panning a map).
	/// A tap inside a frozen detection box snaps to that detection, preserving its
	/// class/confidence/driver; anywhere else becomes a synthetic manual observation.
	private func pick(at location: CGPoint, in size: CGSize) {
		// Snap to a displayed detection: the frozen frame's snapshot is the exact
		// image its boxes came from, so the pair is coherent by construction.
		if let frame = appliedFrame,
		   let hit = FindingCapture.detection(at: location, in: size, results: frame.results) {
			present(FindingCapture(
				observation: hit.observation,
				params: hit.params,
				frame: frame,
				pageURL: appState.browserState.displayedURL
			))
			return
		}

		manualPick(at: location, in: size)
	}

	/// No detection under the tap: a synthetic observation around the point (no
	/// class, no driver). The frozen frame's snapshot is reused when detection is
	/// running; otherwise a fresh one is taken — there may be no frame at all.
	private func manualPick(at location: CGPoint, in size: CGSize) {
		let observation = DetectedObject(
			uuid: UUID(),
			labels: [],
			confidence: 0,
			boundingBox: FindingCapture.manualBox(at: location, in: size),
			regionIndex: 0
		)
		if let frame = appliedFrame {
			present(FindingCapture(
				observation: observation,
				params: nil,
				frame: frame,
				pageURL: appState.browserState.displayedURL
			))
			return
		}
		Task { @MainActor in
			guard let image = await appState.webViewRenderer.snapshot() else {
				LoggingPolicy.error("Manual finding pick: snapshot failed", logger: .ui)
				cancelFindPick()
				return
			}
			present(FindingCapture(
				observation: observation,
				params: nil,
				frame: AppliedDetectionFrame(image: image, results: []),
				pageURL: appState.browserState.displayedURL
			))
		}
	}

	/// Pick mode ends only when the capture is ready (or cancelled): the overlay
	/// keeps blocking scroll/zoom while the fresh-snapshot path is in flight, so
	/// the captured image cannot drift from the tapped location.
	private func present(_ capture: FindingCapture) {
		findPickActive = false
		findingCapture = capture
	}

	/// Leaves pick mode without storing: unfreeze and resume (the sheet path
	/// does the same via its onDismiss).
	private func cancelFindPick() {
		findPickActive = false
		isCapturingFinding = false
		appState.detectionState.findingCaptureEnded()
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

/// Captures ONE tap on the content to mark the place of a finding. The frozen
/// frame's detection boxes are re-drawn SOLID (the live annotations have faded
/// by now) so the user can aim at one; a tap inside snaps to that detection.
/// Slightly dimmed so the mode is visible; scroll/zoom are intentionally
/// blocked while picking — Cancel leaves the mode.
private struct FindPickOverlay: View {
	let results: [DetectionResult]
	let onPick: (CGPoint, CGSize) -> Void
	let onCancel: () -> Void

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .top) {
				Color.black.opacity(0.15)
					.contentShape(Rectangle())
					.gesture(
						SpatialTapGesture()
							.onEnded { value in
								onPick(value.location, geometry.size)
							}
					)
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

	private var hint: some View {
		HStack(spacing: 12) {
			Image(systemName: "plus.viewfinder")
			Text(L10n.Finding.Pick.hint)
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
