//
//  BrowsingHistoryView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct BrowserHistoryView: View {
	@Environment(\.managedObjectContext) var moc
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
					clearSection
					historySection
				}
				// NB: a `.testability` on the List propagates its identifier onto every row,
				// clobbering the per-row / button identifiers UI tests rely on. Row- and
				// control-level identifiers (browsingHistoryItem, browsingHistoryClear, …) are
				// the testability surface here; the screen is anchored by its navigation title.
				.alert(isPresented: $showingAlert) { clearAlert }
			}
		}
		.navigationTitle(L10n.History.title)
		.sheetDismissButton(testability: .browsingHistoryDismiss)
	}

	private var clearSection: some View {
		Section {
			HStack {
				Text(L10n.History.Clear.title)
				Spacer()
				Button(action: {
					showingAlert = true
				}) {
					Text(L10n.History.Clear.button)
						.bold()
						// Destructive action (clears all history) — stable red, matching
						// the alert's destructive confirm button.
						.foregroundColor(.red)
				}
				.testability(Testability.Button.browsingHistoryClear)
			}
		}
	}

	private var historySection: some View {
		Section(header: Text(L10n.History.Section.title)) {
			ForEach(history, id: \.self) { (item: WebHistoryEntry) in
				historyRow(item)
			}
		}
	}

	@ViewBuilder
	private func historyRow(_ item: WebHistoryEntry) -> some View {
		let page = item.page?.absoluteString ?? "Unknown Page"
		HStack {
			Text(page)
				.testability(Testability.Label.browsingHistoryItem)
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

	private var clearAlert: Alert {
		localizedAlert(
			title: L10n.Alert.Warning.title,
			message: L10n.Alert.History.Clear.message,
			primaryButton: .destructive(Text(L10n.History.Clear.button)) {
				do {
					// moc is the viewContext, so merging into [self] is sufficient here.
					try WebHistoryEntry.deleteAll(in: moc)
					refreshFrom.toggle()
				} catch {
					LoggingPolicy.error("Failed to clear browsing history", error: error, logger: .state)
				}
			},
			secondaryButton: .cancel()
		)
	}
}
