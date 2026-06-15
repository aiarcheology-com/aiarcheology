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

import Vision
struct WebScreenView: View {
	@Environment(\.managedObjectContext) var moc
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
	@State private var presentLocationSheet: Bool = false
	@State private var latestError: HistoryError?
	@State private var showAlert: Bool = false
	@State private var hasPerformedInitialAction = false
	/// UI-test introspection: which page the browser decided to load (home/last/blank).
	@State private var intendedPageKind = ""
	@State private var currentPageFile = ""
	@State private var showIdentifiers: Bool = false
	@State private var tiledDetection: Bool = false
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
				WebAddressDisplay {
					presentLocationSheet = true
				}
				if showsTopBarNavigation {
					WebForwardButton()
					WebReloadStopButton()
				}
			}
			.environmentObject(appState.browserState)
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
            tiledDetection: tiledDetection,
            isCapturingFinding: $isCapturingFinding,
            onFrameChanged: { frame in
                appliedFrame = frame
            },
            onInteractionStateChanged: { state in
                // Optionally propagate to Guide for other UI components to observe
                appState.guide.contentInteractionState = state
            }
        ) { interactionState in
            MLWebView(loadRequest, loadStatusChanged: { loading, error in
				LoggingPolicy.debug("WebView loading status changed: \(loading ? "loading" : "loaded")", logger: .ui)
                if let error = error {
					LoggingPolicy.error("WebView loading error: \(error.localizedDescription)", logger: .ui)
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
        .onReceive(appState.settings.$tiledDetection) { value in
            tiledDetection = value
        }
        .onAppear {
            showIdentifiers = appState.settings.showIdentifiers
            tiledDetection = appState.settings.tiledDetection
            if hasPerformedInitialAction.not {
                hasPerformedInitialAction = true
                if let fixtureURL = appState.settings.launchFixtureURL {
                    // AIA-0316 UI-test harness: load a bundled local-HTML fixture directly via
                    // loadFileURL. Highest precedence, and deliberately NOT recorded in history.
                    intendedPageKind = "localFixture"
                    if loadRequest.fileURL != fixtureURL {
                        loadRequest = loadRequest.nextFile(fixtureURL)
                    }
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
        .onReceive(appState.browserState.$currentURL) { url in
            currentPageFile = url?.lastPathComponent ?? ""
        }
        .checkpoint(.currentPageFile, value: currentPageFile)
        .sheet(isPresented: $presentLocationSheet) {
            LocationSheetView(currentURL: appState.browserState.displayedURL?.absoluteString) { input in
                openRequested(input)
            }
            .environmentObject(appState.settings)
        }
        .sheet(item: $findingCapture, onDismiss: {
            // Every dismissal path (Save, Cancel, interactive swipe) ends the
            // capture: unfreeze the displayed frame, then resume the timer —
            // its immediate snapshot replaces the frozen frame right away.
            isCapturingFinding = false
            appState.guide.findingCaptureEnded()
        }) { capture in
            SaveFindingSheet(capture: capture)
        }
        .onReceive(appState.guide.$pageToOpen) { url in
            // A finding's "open page" action lands here (the findings UI cannot
            // reach the web view directly).
            guard let url else { return }
            appState.guide.pageToOpen = nil
            openRequested(url.absoluteString)
        }
        .onReceive(appState.guide.$findModeRequested) { requested in
            guard requested else { return }
            appState.guide.findModeRequested = false
            // Freeze exactly like an annotation tap would: detection passes pause
            // and the displayed frame holds while the user picks the place.
            isCapturingFinding = true
            appState.guide.findingCaptureStarted()
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
        .environmentObject(appState.webViewRenderer)
        .environmentObject(appState.browserState)
        .navigationBarTitle("", displayMode: .inline)
        .clipped()
        .toolbar {
            toolbarContent
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
		appState.webViewRenderer.render(EmptyView(), scale: 1) { image, error in
			guard let image else {
				LoggingPolicy.error("Manual finding pick: snapshot failed", error: error, logger: .ui)
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
		appState.guide.findingCaptureEnded()
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

/// Read-only URL display at maximum width; tapping it presents the location sheet.
private struct WebAddressDisplay: View {
	@EnvironmentObject var browserState: BrowserState
	let action: () -> Void

	var body: some View {
		let urlText = browserState.displayedURL?.absoluteString ?? L10n.Browser.Location.placeholder
		let textColor: Color = browserState.displayedURL == nil ? .secondary : .primary
		Button(action: action) {
			Text(urlText)
				.lineLimit(1)
				.truncationMode(.middle)
				.foregroundColor(textColor)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(5)
				.background(.ultraThinMaterial)
				.overlay(
					RoundedRectangle(cornerRadius: 5)
						.stroke(Color.gray.opacity(0.75), lineWidth: 0.75)
				)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		// VoiceOver reads the actual URL, not just the affordance.
		.accessibilityLabel(urlText)
		.testability(Testability.Button.webScreenAddressBar)
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
