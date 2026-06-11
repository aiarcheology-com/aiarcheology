//
//  LocationSheetView.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import SwiftUI
import CoreData

/// Safari-style location surface: the read-only address display in the top bar presents
/// this sheet, which carries the URL/search input with an explicit Open confirmation and
/// the browsing history (debounce-filtered while typing, sortable, full URLs visible).
/// Replaces the former inline dropdown (`DropdownMenuModifier`).
struct LocationSheetView: View {
	enum SortOrder {
		case recent
		case alphabetical
	}

	@Environment(\.dismiss) private var dismiss
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>

	let onOpen: (String) -> Void

	@State private var searchText: String
	/// Debounced copy of `searchText` that actually drives the filter.
	@State private var filterText: String
	@State private var sortOrder: SortOrder = .recent
	@State private var fullURLs = true
	@FocusState private var searchFocused: Bool

	init(initialText: String, onOpen: @escaping (String) -> Void) {
		self.onOpen = onOpen
		_searchText = State(initialValue: initialText)
		_filterText = State(initialValue: "")
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				inputRow
				List {
					ForEach(filteredEntries, id: \.objectID) { entry in
						historyRow(entry)
					}
				}
				.listStyle(.plain)
			}
			.navigationTitle(L10n.Browser.Location.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItemGroup(placement: .navigationBarLeading) {
					sortMenu
					fullURLsToggle
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: { dismiss() }) {
						Text(L10n.Common.dismiss)
							.bold()
					}
					.testability(Testability.Button.locationSheetDismiss)
				}
			}
		}
		.task {
			// Focus after the sheet's presentation transition; focusing immediately in
			// onAppear is unreliable inside sheets.
			try? await Task.sleep(for: .milliseconds(450))
			searchFocused = true
		}
	}

	// MARK: - Input

	private var inputRow: some View {
		HStack(spacing: 8) {
			TextField(L10n.Browser.Location.placeholder, text: $searchText)
				.testability(Testability.TextField.locationSheetInput)
				.textInputAutocapitalization(.never)
				.disableAutocorrection(true)
				.keyboardType(.URL)
				.submitLabel(.go)
				.focused($searchFocused)
				.onSubmit(of: .text) {
					open(searchText)
				}
				.padding(8)
				.background(.ultraThinMaterial)
				.clipShape(RoundedRectangle(cornerRadius: 8))
			Button(L10n.Browser.Location.open) {
				open(searchText)
			}
			.testability(Testability.Button.locationSheetOpen)
			.buttonStyle(.borderedProminent)
			.disabled(searchText.browserInputType == .unusable)
		}
		.padding(.horizontal)
		.padding(.vertical, 8)
		.task(id: searchText) {
			// Debounce: a fresh keystroke cancels this task, so the filter only follows
			// once typing pauses.
			try? await Task.sleep(for: .milliseconds(250))
			filterText = searchText
		}
	}

	private func open(_ input: String) {
		guard input.browserInputType != .unusable else { return }
		onOpen(input)
		dismiss()
	}

	// MARK: - History list

	private var filteredEntries: [WebHistoryEntry] {
		var entries = history.filter { entry in
			guard let page = entry.page else { return false }
			return filterText.isEmpty || page.absoluteString.localizedCaseInsensitiveContains(filterText)
		}
		if sortOrder == .alphabetical {
			entries.sort { ($0.page?.absoluteString ?? "") < ($1.page?.absoluteString ?? "") }
		}
		return entries
	}

	@ViewBuilder
	private func historyRow(_ entry: WebHistoryEntry) -> some View {
		if let page = entry.page {
			Button {
				open(page.absoluteString)
			} label: {
				VStack(alignment: .leading, spacing: 2) {
					Text(page.absoluteString)
						.lineLimit(fullURLs ? nil : 1)
						.truncationMode(.middle)
						.foregroundColor(.primary)
					if let date = entry.creationDate_ {
						Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
			.testability(Testability.Button.locationSheetHistoryItem)
		}
	}

	// MARK: - Toolbar controls

	private var sortMenu: some View {
		Menu {
			Picker(selection: $sortOrder, label: EmptyView()) {
				Label(L10n.Browser.Location.Sort.recent, systemImage: "clock").tag(SortOrder.recent)
				Label(L10n.Browser.Location.Sort.alphabetical, systemImage: "textformat.abc").tag(SortOrder.alphabetical)
			}
		} label: {
			Image(systemName: "arrow.up.arrow.down")
		}
		.testability(Testability.Button.locationSheetSortOrder)
	}

	private var fullURLsToggle: some View {
		Button {
			fullURLs.toggle()
		} label: {
			Image(systemName: fullURLs ? "text.alignleft" : "ellipsis.rectangle")
		}
		.accessibilityLabel(L10n.Browser.Location.fullUrls)
		.testability(Testability.Button.locationSheetFullUrls)
	}
}
