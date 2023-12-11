//
//  WebScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

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
			Image(systemName:"map").environment(\.symbolVariants, .none)
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
		predicate: NSPredicate(format: "entityId != nil AND page != nil AND creationDate_ != nil"),
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

	init() {
		Backports.Appearance.textField()
	}

var body: some View {
	// Passing appState.webViewRenderer as arg to be able to check, because:
	// https://stackoverflow.com/questions/59822245/swiftui-optional-environment-object
	SnapableGroup(renderer: appState.webViewRenderer, publisher: appState.snap.combinedPublishers) {
		MLWebView(websiteUrl) { loading, error in
				print("loading status : \(loading)")
			}
		}
		.onReceive(appState.guide.$addressSelected) { address in
			guard let address else { return }
			inputUrl = address.absoluteString
			self.websiteUrl = inputUrl
			appState.guide.addressBarMenu = []
		}
		.onAppear() {
			if hasPerformedInitialAction.not {
				hasPerformedInitialAction = true
				if 
					appState.settings.reopenLastPage.enabled,
					let lastPage = history.first?.page?.absoluteString {
					print("lastpage: \(lastPage)")
					inputUrl = lastPage
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
			ToolbarItem(placement: .principal) {

				TextField("Search or enter any website name", text: $inputUrl) { isStart in
					showMenu = isStart
				}
				.environmentObject(appState.guide)
				.onChange(of: inputUrl) { value in
					if let addressSelected = appState.guide.addressSelected,
					   inputUrl == addressSelected.absoluteString {
						// Do not fill in the addressBarMenu if we already have
						// selected an item.
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
				.textFieldStyle(.roundedBorder)
				.textInputAutocapitalization(.never)
				.disableAutocorrection(true)
				.onSubmit(of: .text, {
					self.websiteUrl = inputUrl
					guard inputUrl.browserInputType == .url else { return } // do not store search terms
					createWebHistoryEntry(inputUrl, maxEntries: appState.settings.historySize)
				})
				.alert(isPresented: $showAlert) {
					showAlert = false
					switch latestError {
						case .fullHistory:
							return Alert(title: Text("Warning"), message: Text("Browsing history is full. Increase the web browsing history size in Settings, or delete some existing entries from the history."), dismissButton: .default(Text("OK")))

						default:
							return Alert(title: Text(""))
					}
				}
			}
		}
	}

	private func createWebHistoryEntry(_ urlString: String, maxEntries: Int) {
		guard WebHistoryEntry.getAll(in: moc).count <= maxEntries else {
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
		newHistorEntry.entityId = UUID()
		newHistorEntry.page = URL(string:websiteUrl.withHTTPS)
		do {
			try newHistorEntry.validateForInsert()
		}
		catch let error {
			WebHistoryEntry.delete(newHistorEntry, in: moc)
			assert(false, "The new web history entry is not valid and can not be stored \(error)" )
			return
		}
		WebHistoryEntry.save(in: moc)
	}
}

