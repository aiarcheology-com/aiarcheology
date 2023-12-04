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

import Vision
struct WebScreenView: View {
	@Environment(\.managedObjectContext) var moc
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "entityId != nil AND page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var appState: AppState
	@State private var websiteUrl: String = "https://www.google.com"
	@State private var isWebsiteLoading: Bool = false
	@State private var inputUrl: String = ""
	@State private var showMenu: Bool = false
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
		.onAppear() {
			if hasPerformedInitialAction.not {
				hasPerformedInitialAction = true
				if 
					appState.settings.reopenLastPage.enabled,
					let lastPage = history.first?.page?.absoluteString {
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
				TextField("Search or enter any website name", text: $inputUrl, onEditingChanged: { starts in
					if starts && history.isEmpty.not {
						showMenu = true
					}
				})
				.contextMenu {
					if showMenu {
						ForEach(Array(history), id: \.self){ entry in
							HStack {
								Button(entry.page?.host(percentEncoded: false) ?? "Unknown URL") {
									guard let page = entry.page else {
										assert(false, "The page property of the WebHistoryEntry is nil.")
									}
									inputUrl = page.absoluteString
									self.websiteUrl = inputUrl
									entry.creationDate_ = .now
									WebHistoryEntry.save(in: appState.dataController.container.viewContext)
								}
								// Shows the tags of the entries:
//								Spacer()
//								HStack {
//									ForEach(entry.tagsArray, id: \.self) { tag in
//										Text(tag.identifier ?? "")
//											.padding()
//											.background(Color.blue)
//											.foregroundColor(.white)
//											.cornerRadius(10) //
//									}
//								}
							}
						}
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
			}
		}
	}

	private func createWebHistoryEntry(_ urlString: String, maxEntries: Int) {
		// TODO:  Add the limit for the entries to setting.historySize, remove the oldest entry
		guard 
			WebHistoryEntry.getAll(in: moc).count <= maxEntries,
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

