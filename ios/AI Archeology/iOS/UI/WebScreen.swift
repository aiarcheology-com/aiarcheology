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
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: true)],
		predicate: NSPredicate(format: "entityId != nil AND page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var appState: AppState
	@State private var websiteUrl: String = "https://ags.cuzk.cz/av/?extent=-831332.9688214378,-1117345.0500381005,-639820.6497967998,-1016468.2402844809&zvd=dmr5g&rf=GrayscaleHillshade&o=0"
	@State private var isWebsiteLoading: Bool = false
	@State private var inputUrl: String = ""
	@State private var showMenu: Bool = false

var body: some View {
	// Passing appState.webViewRenderer as arg to be able to check, because:
	// https://stackoverflow.com/questions/59822245/swiftui-optional-environment-object
	SnapableGroup(renderer: appState.webViewRenderer, publisher: appState.snap.combinedPublishers) {
		MLWebView(websiteUrl) { loading, error in
				print("loading status : \(loading)")
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
						ForEach(history, id: \.self){ entry in
							Button(entry.page?.host(percentEncoded: false) ?? "Unknown URL") {
								guard let page = entry.page else {
									assert(false, "The page property of the WebHistoryEntry is nil.")
								}
								appState.guide.openPage(page)
							}
						}
					}
				}
				.textFieldStyle(.roundedBorder)
				.textInputAutocapitalization(.never)
				.disableAutocorrection(true)
				.onSubmit(of: .text, {
					self.websiteUrl = inputUrl
					guard inputUrl.browserInputType == .url else { return }

					let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: moc)
					newHistorEntry.bookmarked = false
					newHistorEntry.creationDate_ = .now
					newHistorEntry.entityId = UUID()
					newHistorEntry.page = URL(string:websiteUrl.withHTTPS)
					do {
						try newHistorEntry.validateForInsert()
					}
					catch let error {
						moc.delete(newHistorEntry)
						assert(false, "The new web history entry is not valid and can not be stored \(error)" )
						return
					}
					WebHistoryEntry.save(in: moc)
				})
				.onReceive(appState.guide.$pageToOpen) { page in
					guard let pageString = page?.absoluteString else { return }
					self.websiteUrl = pageString
				}
			}
		}
	}
}

