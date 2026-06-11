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
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
	@State private var showIdentifiers: Bool = false

	init() {
		Backports.Appearance.textField()
	}

	@ToolbarContentBuilder
	var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .principal) {
			// Regular width groups BACK | ADDRESS | FORWARD | RELOAD together — all
			// browser actions in one cluster, mentally separate from the detection
			// buttons in the trailing group; compact relies on the floating capsule.
			HStack(spacing: 8) {
				if horizontalSizeClass == .regular {
					WebBackButton()
				}
				WebAddressDisplay {
					presentLocationSheet = true
				}
				if horizontalSizeClass == .regular {
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
        .onAppear {
            showIdentifiers = appState.settings.showIdentifiers
            if hasPerformedInitialAction.not {
                hasPerformedInitialAction = true
                if
                    appState.settings.reopenLastPage.enabled,
                    let lastPage = appState.settings.lastPage {
                    // Not a user load: the display gate stays open and KVO fills the bar.
                    loadRequest = loadRequest.next(lastPage.absoluteString)
                } else {
                    guard let defaultPage = appState.settings.defaultPage?.absoluteString else { return }
                    loadRequest = loadRequest.next(defaultPage)
                    createOrRefreshWebHistoryEntry(defaultPage, maxEntries: appState.settings.historySize)
                }
            }
        }
        .sheet(isPresented: $presentLocationSheet) {
            LocationSheetView { input in
                openRequested(input)
            }
            .environmentObject(appState.settings)
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

// MARK: - Browser chrome components

/// Read-only URL display at maximum width; tapping it presents the location sheet.
private struct WebAddressDisplay: View {
	@EnvironmentObject var browserState: BrowserState
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(browserState.displayedURL?.absoluteString ?? L10n.Browser.Location.placeholder)
				.lineLimit(1)
				.truncationMode(.middle)
				.foregroundColor(browserState.displayedURL == nil ? .secondary : .primary)
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
		.accessibilityLabel(browserState.displayedURL?.absoluteString ?? L10n.Browser.Location.placeholder)
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
