//
//  LocationSheetView.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import SwiftUI
import UIKit
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
	@Environment(\.managedObjectContext) private var moc
	@EnvironmentObject private var settings: Settings
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>

	let onOpen: (String) -> Void

	/// Prefilled with the active page URL and selected on the automatic focus
	/// (Safari-style), so copying or tweaking it is immediate; staying on the page
	/// is still just a dismiss.
	@State private var searchText: String
	/// Debounced copy of `searchText` that actually drives the filter.
	@State private var filterText = ""
	@State private var sortOrder: SortOrder = .recent
	@State private var fullURLs = true
	/// Host whose recorded visit trail is pushed as the detail (programmatic navigation —
	/// a NavigationLink in the row would make the List add its own disclosure chevron).
	@State private var trailHost: String?
	@FocusState private var searchFocused: Bool
	/// The active page URL the field was prefilled with. It must not act as a history
	/// filter — the list would collapse to just the current page until the first edit.
	private let prefilledURL: String
	/// Select-all applies only to the automatic focus on appear; a later tap into the
	/// field places the cursor normally.
	@State private var selectAllOnFocus: Bool

	init(currentURL: String? = nil, onOpen: @escaping (String) -> Void) {
		self.onOpen = onOpen
		let prefilled = currentURL ?? ""
		self.prefilledURL = prefilled
		_searchText = State(initialValue: prefilled)
		_selectAllOnFocus = State(initialValue: prefilled.isEmpty.not)
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
			.navigationDestination(item: $trailHost) { host in
				VisitTrailView(host: host, onOpen: open)
			}
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
				.onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
					// SwiftUI has no select-all API; reach the backing UITextField the
					// moment it becomes first responder (this sheet's only text field).
					guard selectAllOnFocus, let field = notification.object as? UITextField else { return }
					selectAllOnFocus = false
					field.selectAll(nil)
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
		.onAppear {
			// Focus only when prefilled: the selected URL is ready to copy or replace.
			// With no active page the field stays unfocused, as before.
			if prefilledURL.isEmpty.not {
				searchFocused = true
			}
		}
		.task(id: searchText) {
			// Debounce: a fresh keystroke cancels this task, so the filter only follows
			// once typing pauses.
			try? await Task.sleep(for: .milliseconds(250))
			filterText = searchText == prefilledURL ? "" : searchText
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
			HStack(spacing: 10) {
				Button {
					open(page.absoluteString)
				} label: {
					HStack(alignment: .top, spacing: 10) {
						// Leading column: favicon, with the home indicator beneath it
						// (same green house as the Browsing History screen).
						VStack(spacing: 8) {
							favicon(for: page)
							if page == settings.defaultPage {
								Image(systemName: "house")
									.foregroundColor(.green)
							}
						}
						VStack(alignment: .leading, spacing: 2) {
							Text(page.absoluteString)
								.lineLimit(fullURLs ? nil : 1)
								.truncationMode(.middle)
								// Explicit: inside a button label, wrapped lines
								// center-align by default.
								.multilineTextAlignment(.leading)
								.foregroundColor(.primary)
							HStack {
								if let date = entry.creationDate_ {
									Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
								}
								Spacer()
								Text(L10n.Browser.Location.visitCount(Int(entry.visitCount)))
							}
							.font(.caption)
							.foregroundStyle(.secondary)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
				}
				.buttonStyle(.borderless)
				.testability(Testability.Button.locationSheetHistoryItem)
				// Context menu doubles every action for iPad-on-Mac, where swipe
				// actions are not reachable with a mouse (right-click opens it).
				.contextMenu {
					Button {
						UIPasteboard.general.string = page.absoluteString
					} label: {
						Label(L10n.Common.copy, systemImage: "doc.on.doc")
					}
					.testability(Testability.Button.locationSheetCopyUrl)
					Button {
						settings.defaultPage = page
					} label: {
						Label(L10n.Browser.Location.setHomePage, systemImage: "house")
					}
					.testability(Testability.Button.locationSheetSetHomePage)
					Button(role: .destructive) {
						deleteEntry(entry)
					} label: {
						Label(L10n.Common.delete, systemImage: "trash")
					}
					.testability(Testability.Button.locationSheetDeleteEntry)
				}

				// Detail-disclosure into the recorded trail of this site — every URL
				// the page settled on (map pans included), to replay the movement.
				// Borderless buttons keep the two tap targets independent in the row.
				if let host = page.host {
					Button {
						// Resign the input session before the push — transferring it
						// mid-transition makes UIKit log keyboard-placeholder
						// constraint breaks (system-internal, but noisy).
						searchFocused = false
						trailHost = host
					} label: {
						Image(systemName: "info.circle")
							.foregroundStyle(.secondary)
							.frame(minWidth: 32, minHeight: 32)
							.contentShape(Rectangle())
					}
					.buttonStyle(.borderless)
					.accessibilityLabel(L10n.Browser.Location.trail)
					.testability(Testability.Button.locationSheetVisitTrail)
				}
			}
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				Button(role: .destructive) {
					deleteEntry(entry)
				} label: {
					Label(L10n.Common.delete, systemImage: "trash")
				}
				.testability(Testability.Button.locationSheetDeleteEntry)
				Button {
					settings.defaultPage = page
				} label: {
					Label(L10n.Browser.Location.setHomePage, systemImage: "house")
				}
				.tint(.green)
				.testability(Testability.Button.locationSheetSetHomePage)
			}
		}
	}

	private func deleteEntry(_ entry: WebHistoryEntry) {
		// Capture the id before deletion — Core Data nullifies attributes on delete.
		let entityId = entry.entityId
		WebHistoryEntry.delete(entityId, in: moc)
	}

	/// Best-effort site icon from the conventional /favicon.ico location; sites that
	/// only declare an icon via <link rel="icon"> fall back to the globe symbol.
	private func favicon(for page: URL) -> some View {
		AsyncImage(url: faviconURL(for: page)) { image in
			image
				.resizable()
				.scaledToFit()
		} placeholder: {
			Image(systemName: "globe")
				.foregroundStyle(.secondary)
		}
		.frame(width: 20, height: 20)
		.clipShape(RoundedRectangle(cornerRadius: 4))
	}

	private func faviconURL(for page: URL) -> URL? {
		guard let host = page.host else { return nil }
		return URL(string: "https://\(host)/favicon.ico")
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
		.accessibilityLabel(L10n.Browser.Location.Sort.label)
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

// MARK: - Website data

/// Website-data management for one site: deletes the cookies, caches and other data
/// that this site's pages stored (domain-scoped `WebCacheCleaner`). Pushed onto the
/// location sheet's navigation stack — the system back button returns to the trail.
private struct WebsiteDataView: View {
	@State private var cleaned = false

	let domain: String

	var body: some View {
		List {
			Section {
				Button(role: .destructive) {
					Task {
						await WebCacheCleaner.clean(domain: domain)
						cleaned = true
					}
				} label: {
					HStack {
						Text(L10n.Browser.Location.DataSheet.deleteCookies)
						if cleaned {
							Spacer()
							Image(systemName: "checkmark")
								.foregroundStyle(.secondary)
						}
					}
				}
				.disabled(cleaned)
				.testability(Testability.Button.dataSheetDeleteCookies)
			} footer: {
				Text(L10n.Browser.Location.DataSheet.description)
			}
		}
		.navigationTitle(L10n.Browser.Location.DataSheet.title)
		.navigationBarTitleDisplayMode(.inline)
	}
}

// MARK: - Visit trail detail

/// The complete recorded trail of one site — every URL the page settled on, including
/// the History-API changes a map application makes while panning. Tapping a row reopens
/// that exact URL, replaying the position.
///
/// Matching is by shared registrable domain, not exact host: map portals commonly
/// redirect (geoportal.bayern.de → atlas.bayern.de), and the panning happens on the
/// redirected host while the history entry keeps the typed one. Heuristic: the last two
/// host labels — sites under two-part public suffixes (e.g. *.co.uk) may over-match.
private struct VisitTrailView: View {
	@Environment(\.managedObjectContext) private var moc
	@Environment(\.dismiss) private var dismiss
	@FetchRequest private var visits: FetchedResults<WebVisit>

	private let domain: String
	let onOpen: (String) -> Void

	@State private var presentDataSheet = false
	@State private var confirmDeleteSite = false

	init(host: String, onOpen: @escaping (String) -> Void) {
		self.onOpen = onOpen
		let domain = Self.registrableDomain(of: host)
		self.domain = domain
		_visits = FetchRequest(
			sortDescriptors: [NSSortDescriptor(keyPath: \WebVisit.creationDate_, ascending: false)],
			predicate: NSPredicate(
				format: "(host == %@ OR host ENDSWITH %@) AND page != nil AND creationDate_ != nil",
				domain, "." + domain
			),
			animation: .default)
	}

	private static func registrableDomain(of host: String) -> String {
		let labels = host.split(separator: ".")
		guard labels.count > 2 else { return host }
		return labels.suffix(2).joined(separator: ".")
	}

	var body: some View {
		List {
			if visits.isEmpty {
				Text(L10n.Browser.Location.Trail.empty)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 32)
			}
			ForEach(visits, id: \.objectID) { visit in
				if let page = visit.page {
					Button {
						onOpen(page.absoluteString)
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							Text(page.absoluteString)
								.multilineTextAlignment(.leading)
								.foregroundColor(.primary)
							if let date = visit.creationDate_ {
								Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
					.testability(Testability.Button.visitTrailItem)
					.contextMenu {
						Button {
							UIPasteboard.general.string = page.absoluteString
						} label: {
							Label(L10n.Common.copy, systemImage: "doc.on.doc")
						}
						.testability(Testability.Button.visitTrailCopyUrl)
						Button(role: .destructive) {
							deleteVisit(visit)
						} label: {
							Label(L10n.Common.delete, systemImage: "trash")
						}
						.testability(Testability.Button.visitTrailDeleteEntry)
					}
					.swipeActions(edge: .trailing, allowsFullSwipe: true) {
						Button(role: .destructive) {
							deleteVisit(visit)
						} label: {
							Label(L10n.Common.delete, systemImage: "trash")
						}
						.testability(Testability.Button.visitTrailDeleteEntry)
					}
				}
			}
		}
		.listStyle(.plain)
		.navigationTitle(domain)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Button(L10n.Browser.Location.data) {
					presentDataSheet = true
				}
				.testability(Testability.Button.visitTrailData)
			}
			// Separate glass capsules: without the spacer the system coalesces
			// adjacent trailing items into one shared pill.
			if #available(iOS 26.0, *) {
				ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				Button(role: .destructive) {
					confirmDeleteSite = true
				} label: {
					Text(L10n.Common.delete)
						.foregroundColor(.red)
				}
				.testability(Testability.Button.visitTrailDeleteSite)
			}
		}
		.confirmationDialog(
			L10n.Browser.Location.DeleteHistory.confirm,
			isPresented: $confirmDeleteSite,
			titleVisibility: .visible
		) {
			Button(L10n.Common.delete, role: .destructive) {
				deleteSiteHistory()
			}
		}
		.navigationDestination(isPresented: $presentDataSheet) {
			WebsiteDataView(domain: domain)
		}
	}

	private func deleteVisit(_ visit: WebVisit) {
		// Capture the id before deletion — Core Data nullifies attributes on delete.
		let entityId = visit.entityId
		WebVisit.delete(entityId, in: moc)
	}

	/// Deletes everything this app stored about the site: its history entries and the
	/// recorded visit trail. (Cookies/site data live in the separate Data sheet.)
	/// One context save for the whole batch — per-row `delete(_:in:)` would fetch and
	/// save for every object.
	private func deleteSiteHistory() {
		let matchesDomain: (String?) -> Bool = { host in
			guard let host else { return false }
			return host == domain || host.hasSuffix("." + domain)
		}

		visits.forEach(moc.delete)
		WebHistoryEntry.selectAll(in: moc)
			.filter { matchesDomain($0.page?.host) }
			.forEach(moc.delete)
		do {
			try WebVisit.save(in: moc)
		} catch {
			LoggingPolicy.error("Failed to delete the site's history", error: error, logger: .state)
		}

		// The detail's subject is gone; pop back to the history list.
		dismiss()
	}
}
