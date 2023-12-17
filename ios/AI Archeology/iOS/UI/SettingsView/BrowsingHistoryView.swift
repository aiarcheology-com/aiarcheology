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
		predicate: NSPredicate(format: "entityId != nil AND page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@EnvironmentObject var settings: Settings
	@State private var refreshFrom: Bool = false // TODO: history is not being reloaded after deletion

	var body: some View {
		VStack {
			Form {
				List {
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
									.tint(.blue)

									Button(role: .destructive, action: {
										guard let entityId = item.entityId else {
											assert(false, "No entry has been found after the selection.")
											return
										}
										WebHistoryEntry.delete(entityId, in: moc)
									}) {
										Label("", systemImage: "trash")
									}

									Button(action: {
										settings.defaultPage = item.page
									}) {
										Label("", systemImage: "house")
									}
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
		}
		.navigationTitle("Browsing History")
		.navigationBarItems(trailing: Button(action: {
			WebHistoryEntry.deleteAll(in: moc, executeAndMerge: true)
			refreshFrom.toggle()
			self.presentation.wrappedValue.dismiss()
		}) {
			Text("Clear").bold()
				.foregroundColor(refreshFrom.disabled ? .red : .blue)
		}
		)
	}
}
