//
//  BrowsingHistoryView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct BrowserHistoryView: View {
	@Environment(\.managedObjectContext) var moc
	@Environment(\.presentationMode) var presentation
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "lifeCycleString == %@ AND page != nil AND creationDate_ != nil", "ready"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var settings: Settings
	@State private var refreshFrom: Bool = false // TODO: history is not being reloaded after deletion
	@State private var showingAlert = false

	var body: some View {
		VStack {
			Form {
				List {
					Section {
						HStack {
							Text("Clear Browsing History")
							Spacer()
							Button(action: {
								showingAlert = true
							}) {
								Text("Clear")
									.bold()
									.foregroundColor(refreshFrom.disabled ? .red : .blue)
							}
							.testability(Testability.Button.browsingHistoryClear)
						}
					}
					Section(header: Text("History")) {
						ForEach(history, id: \.self) { (item: WebHistoryEntry) in
							let page = item.page?.absoluteString ?? "Unknown Page"
							HStack {
								Text(page)
									.swipeActions {
										Button(action: {
											UIPasteboard.general.string = page
										}) {
											Label("", systemImage: "doc.on.doc")
										}
										.testability(Testability.Button.browsingHistoryCopyUrl)
										.tint(.blue)

										Button(role: .destructive, action: {
											let entityId = item.entityId
											WebHistoryEntry.delete(entityId, in: moc)
										}) {
											Label("", systemImage: "trash")
										}
										.testability(Testability.Button.browsingHistoryDeleteEntry)

										Button(action: {
											settings.defaultPage = item.page
										}) {
											Label("", systemImage: "house")
										}
										.testability(Testability.Button.browsingHistorySetDefaultPage)
										.tint(.green)
									}
								Spacer()
								if item.page == settings.defaultPage {
									Image(systemName: "house")
										.foregroundColor(.green)
								}
							}
						}
					}
				}
				.testability(Testability.List.browsingHistoryList)
				.alert(isPresented: $showingAlert) {
					Alert(
						title: Text("Warning"),
						message: Text("Clear the browsing history?"),
						primaryButton: .destructive(Text("Clear")) {
							WebHistoryEntry.deleteAll(in: moc, executeAndMerge: true)
							refreshFrom.toggle()
						},
						secondaryButton: .cancel()
					)
				}
			}
		}
		.navigationTitle("Browsing History")
		.navigationBarItems(trailing: Button(action: {
			self.presentation.wrappedValue.dismiss()
		}) {
			Text("Dismiss")
				.bold()
				.foregroundColor(.blue)
		}
		.testability(Testability.Button.browsingHistoryDismiss)
		)
	}
}
