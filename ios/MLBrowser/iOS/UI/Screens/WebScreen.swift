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
		Text("Web")
	}

}

enum HistoryError: Error {
	case fullHistory
}

import Vision
struct WebScreenView: View {
	@Environment(\.managedObjectContext) var moc
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var appState: AppState
	@State private var webScreenUpdate: Bool = false
	@State private var websiteUrl: String = "https://www.google.com"
	@State private var isWebsiteLoading: Bool = false
	@State private var inputUrl: String = ""
	@State private var showMenu: Bool = false
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
			addressBarTextField
		}
	}

	private var addressBarTextField: some View {
		TextField("Search or enter any website name", text: $inputUrl) { isStart in
			showMenu = isStart
		}
		.testability(Testability.TextField.webScreenAddressBar)
		.environmentObject(appState.guide)
		.onChange(of: inputUrl) { _, value in
			handleInputUrlChange(value)
		}
		.padding(5)
		.background(.ultraThinMaterial)
		.overlay(addressBarBorder)
		.textInputAutocapitalization(.never)
		.disableAutocorrection(true)
		.onSubmit(of: .text) {
			handleAddressBarSubmit()
		}
		.alert(isPresented: $showAlert) {
			alertForError(latestError)
		}
	}

	private var addressBarBorder: some View {
		RoundedRectangle(cornerRadius: 5)
			.stroke(Color.gray.opacity(0.75), lineWidth: 0.75)
	}

	private func handleInputUrlChange(_ value: String) {
		if let addressSelected = appState.guide.addressSelected,
		   inputUrl == addressSelected.absoluteString {
			appState.guide.addressSelected = nil
			appState.guide.addressBarMenu = []
			return
		}
		if history.isEmpty.not, showMenu.enabled {
			appState.guide.addressBarMenu = history
				.filter { $0.page?.absoluteString.contains(value) == true }
				.compactMap { $0.page }
		} else {
			appState.guide.addressBarMenu = []
		}
	}

	private func handleAddressBarSubmit() {
		self.websiteUrl = inputUrl
		guard inputUrl.browserInputType == .url else { return }
		createWebHistoryEntry(inputUrl, maxEntries: appState.settings.historySize)
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
            MLWebView(websiteUrl, lastPage: { urlPage in
                appState.settings.lastPage = urlPage
            }, loadStatusChanged: { loading, error in
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
        .onReceive(appState.guide.$addressSelected) { address in
            guard let address else { return }
            inputUrl = address.absoluteString
            self.websiteUrl = inputUrl
            appState.guide.addressBarMenu = []
        }
        .onAppear {
            showIdentifiers = appState.settings.showIdentifiers
            if hasPerformedInitialAction.not {
                hasPerformedInitialAction = true
                if
                    appState.settings.reopenLastPage.enabled,
                    let lastPage = appState.settings.lastPage {
                    inputUrl = lastPage.absoluteString
                    self.websiteUrl = inputUrl
                } else {
                    guard let defaultPage = appState.settings.defaultPage?.absoluteString else { return }
                    inputUrl = defaultPage
                    self.websiteUrl = inputUrl
                    createWebHistoryEntry(inputUrl, maxEntries: appState.settings.historySize)
                }
            }
        }
        .environmentObject(appState.webViewRenderer)
        .navigationBarTitle("", displayMode: .inline)
        .clipped()
        .toolbar {
            toolbarContent
        }
    }

	private func alertForError(_ error: HistoryError?) -> Alert {
		switch error {
		case .fullHistory:
			return Alert(
				title: Text("Warning"),
				message: Text("Browsing history is full. Increase the web browsing history size in Settings, or delete some existing entries from the history."),
				dismissButton: .default(Text("OK"))
			)
		case .none:
			return Alert(title: Text(""))
		}
	}

	private func createWebHistoryEntry(_ urlString: String, maxEntries: Int) {
		// Use existing @FetchRequest count instead of fetching all objects
		guard history.count <= maxEntries else {
			latestError = HistoryError.fullHistory
			showAlert = true
			return
		}

		guard
			history.contains(where: { $0.page?.absoluteString == urlString }).not else {
			return
		}

		let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: moc)
		newHistorEntry.bookmarked = false
		newHistorEntry.creationDate_ = .now
		newHistorEntry.page = URL(string: websiteUrl.withHTTPS)
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
		WebHistoryEntry.save(in: moc)
	}
}
