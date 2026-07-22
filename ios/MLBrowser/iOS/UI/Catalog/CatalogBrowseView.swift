//
//  CatalogBrowseView.swift
//  AI Archeology
//
//  AIA-0413: catalog search and package-download presentation.
//

import CoreData
import SwiftUI

/// A catalog family-filter selection. A plain `Set<ModelFamily>` cannot represent the "Other"
/// bucket (entries whose `family` is `nil`), so the nil-family case is modelled explicitly here
/// (AIA-0497). Display/filter only — it never drives labels, task, or preprocessing.
enum CatalogFamilyFilter: Hashable {
	case family(ModelFamily)
	case other
}

extension CatalogFamilyFilter {
	/// Chip label. Family names are non-localized proper nouns; the "Other" bucket is localized.
	var displayName: String {
		switch self {
		case .family(let family): return family.displayName
		case .other: return L10n.Catalog.Filter.Family.other
		}
	}

	/// A stable, non-localized suffix so UI tests target the chip by identifier, not by its text.
	var testabilityLabel: String {
		switch self {
		case .family(let family): return family.rawValue
		case .other: return "other"
		}
	}
}

struct CatalogBrowseView: View {
	@Environment(\.managedObjectContext) private var managedObjectContext
	@EnvironmentObject private var downloader: Downloader

	let onImport: ImportHandler
	@ObservedObject private var searchManager: CatalogSearchManager
	@State private var selectionTask: Task<Void, Never>?
	@State private var downloadItem: DownloadItem?
	@State private var isShowingDownloads = false
	@State private var selectionErrorMessage: String?
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
		animation: .default
	)
	private var downloadItems: FetchedResults<DownloadItem>
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \DeepConfiguration.creationDate_, ascending: false)],
		animation: .default
	)
	private var configurations: FetchedResults<DeepConfiguration>

	private var newestDownloadItemsByURL: [URL: DownloadItem] {
		downloadItems.reduce(into: [:]) { result, item in
			guard let url = item.url, result[url] == nil else { return }
			result[url] = item
		}
	}

	private var importedConfigurationURLs: Set<URL> {
		Set(configurations.compactMap(\.downloadURL))
	}

	init(searchManager: CatalogSearchManager, onImport: ImportHandler) {
		self.onImport = onImport
		_searchManager = ObservedObject(wrappedValue: searchManager)
	}

	var body: some View {
		List {
			searchSection
			providerSection
			resultProviderFilters
			taskFilters
			familyFilters
			resultsSection
		}
		.listStyle(.insetGrouped)
		.navigationTitle(L10n.Catalog.title)
		.navigationBarTitleDisplayMode(.inline)
		.navigationDestination(item: $downloadItem) { item in
			DownloadDetailView(item: item, onImport: onImport)
		}
		.navigationDestination(isPresented: $isShowingDownloads) {
			DownloaderView(onImport: onImport, showsDismissButton: false)
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button(L10n.Catalog.downloads) {
					isShowingDownloads = true
				}
				.foregroundStyle(.blue)
				.testability(Testability.Button.catalogDownloads)
			}
		}
		.onDisappear {
			selectionTask?.cancel()
			searchManager.cancelSearch()
		}
		.alert(L10n.Catalog.Error.title, isPresented: .init(
			get: { selectionErrorMessage != nil },
			set: { if !$0 { selectionErrorMessage = nil } }
		)) {
			Button(L10n.Common.ok, role: .cancel) { }
		} message: {
			Text(selectionErrorMessage ?? L10n.Catalog.Error.message)
		}
	}
}

private extension CatalogBrowseView {
	var searchSection: some View {
		Section {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField(L10n.Catalog.Search.prompt, text: queryBinding)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.testability(Testability.TextField.catalogSearch)
			}
		}
	}

	var queryBinding: Binding<String> {
		Binding(
			get: { searchManager.query },
			set: { searchManager.updateQuery($0) }
		)
	}

	var providerSection: some View {
		Section(L10n.Catalog.provider) {
			Menu {
				ForEach(searchManager.providerDescriptors) { provider in
					Button {
						searchManager.toggleProvider(id: provider.id)
					} label: {
						if searchManager.selectedProviderIDs.contains(provider.id) {
							Label(provider.displayName, systemImage: "checkmark")
						} else {
							Label(provider.displayName, systemImage: provider.isSearchable ? "square" : "archivebox")
						}
					}
					.disabled(provider.isSearchable == false)
				}
			} label: {
				HStack {
					Label(L10n.Catalog.provider, systemImage: "square.stack.3d.up")
					Spacer()
					Text(searchManager.selectedProviderSummary)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					Image(systemName: "chevron.up.chevron.down")
						.foregroundStyle(.tertiary)
				}
			}
			.testability(Testability.Picker.catalogProvider)
		}
	}

	@ViewBuilder
	var resultProviderFilters: some View {
		if searchManager.searchableProviderDescriptors.count > 1 {
			Section {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						providerFilterButton(title: L10n.Catalog.Results.allSources, providerID: nil)
						ForEach(searchManager.searchableProviderDescriptors) { provider in
							providerFilterButton(title: provider.displayName, providerID: provider.id)
						}
					}
					.padding(.vertical, 2)
				}
			}
			.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
		}
	}

	func providerFilterButton(title: String, providerID: String?) -> some View {
		Button {
			searchManager.filterResults(to: providerID)
		} label: {
			Text(title)
				.font(.subheadline)
				.fontWeight(searchManager.resultProviderFilterID == providerID ? .semibold : .regular)
				.foregroundStyle(searchManager.resultProviderFilterID == providerID ? .white : .primary)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.background(searchManager.resultProviderFilterID == providerID ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
		}
		.buttonStyle(.plain)
		.testability(Testability.Button.catalogProviderFilter, label: providerID ?? "all")
		.disabled(providerID.map { searchManager.selectedProviderIDs.contains($0) == false } ?? false)
		.opacity(providerID.map { searchManager.selectedProviderIDs.contains($0) ? 1 : 0.45 } ?? 1)
	}

	var taskFilters: some View {
		Section {
			filterChipRow {
				filterChip(
					title: L10n.Catalog.Filter.Task.classification,
					isSelected: searchManager.selectedTasks.contains(.imageClassification),
					testabilityID: .catalogTaskFilter,
					testabilityLabel: CatalogTask.imageClassification.rawValue
				) {
					searchManager.toggleTask(.imageClassification)
				}
				filterChip(
					title: L10n.Catalog.Filter.Task.detection,
					isSelected: searchManager.selectedTasks.contains(.objectDetection),
					testabilityID: .catalogTaskFilter,
					testabilityLabel: CatalogTask.objectDetection.rawValue
				) {
					searchManager.toggleTask(.objectDetection)
				}
			}
		} header: {
			filterSectionHeader(L10n.Catalog.Filter.Task.title)
		}
		.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
	}

	var familyFilters: some View {
		Section(L10n.Catalog.Filter.Model.title) {
			filterChipRow {
				ForEach(ModelFamily.allCases, id: \.self) { family in
					familyChip(.family(family))
				}
				familyChip(.other)
			}
		}
		.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
	}

	func familyChip(_ filter: CatalogFamilyFilter) -> some View {
		filterChip(
			title: filter.displayName,
			isSelected: searchManager.selectedFamilies.contains(filter),
			testabilityID: .catalogFamilyFilter,
			testabilityLabel: filter.testabilityLabel
		) {
			searchManager.toggleFamily(filter)
		}
	}

	func filterChipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				content()
			}
			.padding(.vertical, 2)
		}
	}

	func filterChip(
		title: String,
		isSelected: Bool,
		testabilityID: Testability.Button,
		testabilityLabel: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Text(title)
				.font(.subheadline)
				.fontWeight(isSelected ? .semibold : .regular)
				.foregroundStyle(isSelected ? .white : .primary)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
		}
		.buttonStyle(.plain)
		.testability(testabilityID, label: testabilityLabel)
	}

	@ViewBuilder
	func filterSectionHeader(_ title: String) -> some View {
		HStack {
			Text(title)
			Spacer()
			if searchManager.hasActiveFilters {
				Button(L10n.Catalog.Filter.clear) {
					searchManager.clearFilters()
				}
				.font(.caption)
				.textCase(nil)
				.foregroundStyle(.blue)
				.testability(Testability.Button.catalogClearFilters)
			}
		}
	}

	@ViewBuilder
	var resultsSection: some View {
		let newestDownloadItemsByURLSnapshot = newestDownloadItemsByURL
		let importedConfigurationURLsSnapshot = importedConfigurationURLs
		Section {
			if searchManager.isLoading {
				HStack {
					Spacer()
					ProgressView()
					Spacer()
				}
			} else if let errorMessage = searchManager.errorMessage {
				ContentUnavailableView(
					L10n.Catalog.Error.title,
					systemImage: "exclamationmark.triangle",
					description: Text(errorMessage)
				)
			} else if searchManager.visibleResults.isEmpty {
				if searchManager.hasResultsHiddenByFilters {
					ContentUnavailableView(
						L10n.Catalog.Filter.emptyTitle,
						systemImage: "line.3.horizontal.decrease.circle",
						description: Text(L10n.Catalog.Filter.emptyMessage)
					)
				} else {
					ContentUnavailableView(
						searchManager.query.isEmpty ? L10n.Catalog.Empty.title : L10n.Catalog.Empty.noResultsTitle,
						systemImage: "magnifyingglass",
						description: Text(searchManager.query.isEmpty ? L10n.Catalog.Empty.message : L10n.Catalog.Empty.noResultsMessage)
					)
				}
		} else {
				ForEach(searchManager.visibleResults) { model in
					let artifactURL = searchManager.resolvedArtifactURL(for: model)
					let item = artifactURL.flatMap { newestDownloadItemsByURLSnapshot[$0] }
					let isImported = item?.state == .imported || artifactURL.map(importedConfigurationURLsSnapshot.contains) == true
					Button {
						select(model)
					} label: {
						CatalogResultRow(
							model: model,
							providerName: searchManager.providerName(for: model.providerId),
							isResolving: searchManager.resolvingModelID == model.id,
							downloadItem: item,
							isImported: isImported
						)
					}
					.buttonStyle(.plain)
					.contentShape(Rectangle())
					.disabled(searchManager.resolvingModelID != nil)
					.testability(Testability.Button.catalogResult)
				}
			}
		} header: {
			Text(L10n.Catalog.Results.title)
		}
		.testability(Testability.List.catalogResults)
	}

	func select(_ model: CatalogModel) {
		selectionTask?.cancel()
		selectionTask = Task { @MainActor [searchManager] in
			guard let files = await searchManager.resolveFiles(for: model) else { return }
			guard Task.isCancelled == false else { return }
			guard files.isEmpty == false else {
				selectionErrorMessage = L10n.Catalog.Error.unsupportedModel
				return
			}

			do {
				downloadItem = try downloader.catalogDownloadItem(
					files: files,
					catalogSource: searchManager.providerName(for: model.providerId),
					in: managedObjectContext
				)
			} catch {
				selectionErrorMessage = L10n.Catalog.Error.message
			}
		}
	}

}

private struct CatalogResultRow: View {
	let model: CatalogModel
	let providerName: String
	let isResolving: Bool
	let downloadItem: DownloadItem?
	let isImported: Bool

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "cube.box")
				.foregroundStyle(.blue)
				.font(.title3)
				.frame(width: 28)

			VStack(alignment: .leading, spacing: 5) {
				Text(model.displayName)
					.foregroundStyle(.primary)
					.lineLimit(2)
				Text(verbatim: "\(model.author) · \(providerName)")
					.font(.subheadline)
					.foregroundStyle(.secondary)

				metadata
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			if isResolving {
				ProgressView()
			} else {
				Image(systemName: "chevron.right")
					.foregroundStyle(.tertiary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, 3)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private var metadata: some View {
		ViewThatFits(in: .horizontal) {
			HStack(spacing: 12) {
				metrics
				tags
				Spacer(minLength: 0)
				status
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			VStack(alignment: .leading, spacing: 5) {
				metrics
				tags
				status
			}
		}
	}

	@ViewBuilder
	private var metrics: some View {
		if model.downloads > 0 || model.likes > 0 {
			HStack(spacing: 10) {
				if model.downloads > 0 {
					metric(
						model.downloads,
						systemImage: "arrow.down.circle",
						accessibilityLabel: L10n.Catalog.Results.downloads(model.downloads)
					)
				}
				if model.likes > 0 {
					metric(
						model.likes,
						systemImage: "heart",
						accessibilityLabel: L10n.Catalog.Results.likes(model.likes)
					)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
		}
	}

	private func metric(_ value: Int, systemImage: String, accessibilityLabel: String) -> some View {
		Label(value.formatted(), systemImage: systemImage)
			.accessibilityLabel(accessibilityLabel)
	}

	private var tags: some View {
		HStack(spacing: 6) {
			catalogTag
			formatTag
			supportBadge
			if let sizeBytes = model.sizeBytes {
				Text(Int(sizeBytes).formatBytesAsHumanReadable())
					.tagStyle()
			}
		}
	}

	/// The artifact format tag, derived from `model.format`. A `nil` format renders no tag: absent is
	/// honest, whereas guessing "Core ML" for an unresolved result would not be (AIA-0497).
	@ViewBuilder
	private var formatTag: some View {
		switch model.format {
		case .mlmodel, .mlpackage:
			Text(L10n.Catalog.Results.coreML)
				.tagStyle()
		case .onnx:
			Text(L10n.Catalog.Results.onnx)
				.tagStyle()
		case nil:
			EmptyView()
		}
	}

	/// A subtle on-device-support badge (AIA-0497). `.coreMLNative` shows none — its Core ML format
	/// tag already communicates that it imports directly.
	@ViewBuilder
	private var supportBadge: some View {
		switch model.support {
		case .verifiedConvertible:
			supportBadgeLabel(L10n.Catalog.Support.verified)
		case .verifiedGeometryGenericLabels:
			supportBadgeLabel(L10n.Catalog.Support.genericLabels)
		case .convertible:
			supportBadgeLabel(L10n.Catalog.Support.convertible)
		case .coreMLNative:
			EmptyView()
		}
	}

	private func supportBadgeLabel(_ text: String) -> some View {
		Text(text)
			.font(.caption2)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 6)
			.padding(.vertical, 3)
			.overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
	}

	@ViewBuilder
	private var status: some View {
		if let downloadItem {
			CatalogDownloadStatus(item: downloadItem)
		} else if isImported {
			Label(L10n.Common.imported, systemImage: "checkmark.circle.fill")
				.font(.caption)
				.foregroundStyle(.green)
		}
	}

	@ViewBuilder
	private var catalogTag: some View {
		switch model.task {
		case .objectDetection:
			Text(L10n.Catalog.Results.objectDetection)
				.tagStyle()
		case .imageClassification:
			Text(L10n.Catalog.Results.imageClassification)
				.tagStyle()
		}
	}
}

private struct CatalogDownloadStatus: View {
	@ObservedObject var item: DownloadItem

	@ViewBuilder
	var body: some View {
		switch item.state {
		case .notStarted:
			statusLabel(item.state.localizedName, systemImage: "clock", color: .secondary)
		case .downloading:
			statusLabel(progressText, systemImage: "arrow.down.circle.fill", color: .blue)
		case .paused:
			statusLabel(item.state.localizedName, systemImage: "pause.circle.fill", color: .orange)
		case .cancelled:
			statusLabel(item.state.localizedName, systemImage: "xmark.circle.fill", color: .secondary)
		case .failed, .importFailed:
			VStack(alignment: .leading, spacing: 2) {
				statusLabel(item.state.localizedName, systemImage: "exclamationmark.circle.fill", color: .red)

				if let error = item.error, !error.isEmpty {
					Text(error)
						.font(.caption2)
						.foregroundStyle(.red)
						.lineLimit(2)
				}
			}
		case .complete:
			statusLabel(item.state.localizedName, systemImage: "checkmark.circle.fill", color: .green)
		case .imported:
			statusLabel(item.state.localizedName, systemImage: "checkmark.circle.fill", color: .green)
		}
	}

	private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
		Label(text, systemImage: systemImage)
			.font(.caption)
			.foregroundStyle(color)
	}

	private var progressText: String {
		min(max(item.progress, 0), 1)
			.formatted(.percent.precision(.fractionLength(0)))
	}
}

private extension View {
	func tagStyle() -> some View {
		font(.caption2)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 6)
			.padding(.vertical, 3)
			.background(.quaternary, in: Capsule())
	}
}

@MainActor
final class CatalogSearchManager: ObservableObject {
	@Published private(set) var query = ""
	@Published private(set) var selectedProviderIDs: Set<String>
	@Published private(set) var results: [CatalogModel] = []
	@Published private(set) var isLoading = false
	@Published private(set) var errorMessage: String?
	@Published private(set) var resolvingModelID: String?
	@Published private(set) var resultProviderFilterID: String?
	@Published private(set) var selectedTasks: Set<CatalogTask> = []
	@Published private(set) var selectedFamilies: Set<CatalogFamilyFilter> = []

	let providerDescriptors: [CatalogProviderDescriptor]
	private let providersByID: [String: any CatalogProvider]
	private let searchDebounce: Duration
	private var searchTask: Task<Void, Never>?
	private var resolvedFilesByModelID: [String: [CatalogFile]] = [:]

	init(providers: [any CatalogProvider], searchDebounce: Duration = .milliseconds(350)) {
		let descriptors = providers.map(\.descriptor)
		self.providerDescriptors = descriptors
		self.providersByID = Dictionary(uniqueKeysWithValues: zip(descriptors.map(\.id), providers))
		self.selectedProviderIDs = Set(descriptors.filter(\.isSearchable).map(\.id))
		self.searchDebounce = searchDebounce
	}

	deinit {
		searchTask?.cancel()
	}

	func updateQuery(_ newQuery: String) {
		query = newQuery
		searchCurrentQuery()
	}

	func searchCurrentQuery() {
		searchTask?.cancel()
		resolvedFilesByModelID.removeAll(keepingCapacity: true)
		let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		let providers = selectedProviderIDs.compactMap { providersByID[$0] }
		let shouldSearch = trimmedQuery.count >= 2 || hasActiveFilters
		guard shouldSearch, providers.isEmpty == false else {
			isLoading = false
			results = []
			errorMessage = nil
			return
		}

		isLoading = true
		errorMessage = nil
		let selectedProviderIDsSnapshot = selectedProviderIDs
		let searchDebounceSnapshot = searchDebounce
		searchTask = Task { [weak self] in
			do {
				try await Task.sleep(for: searchDebounceSnapshot)
				try Task.checkCancellation()
				let outcome = await withTaskGroup(of: Result<[CatalogModel], Error>.self, returning: SearchOutcome.self) { group in
					for provider in providers {
						group.addTask {
							do {
								return .success(try await provider.search(query: trimmedQuery))
							} catch {
								return .failure(error)
							}
						}
					}

					var models: [CatalogModel] = []
					var didSucceed = false
					for await result in group {
						if case .success(let sourceModels) = result {
							didSucceed = true
							models.append(contentsOf: sourceModels)
						}
					}
					return SearchOutcome(models: models, didSucceed: didSucceed)
				}
				try Task.checkCancellation()
				guard let self,
					  self.selectedProviderIDs == selectedProviderIDsSnapshot,
					  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery else {
					return
				}
				var seen = Set<String>()
				self.results = outcome.models
					.filter { seen.insert("\($0.providerId):\($0.id)").inserted }
					.sorted { lhs, rhs in
						let lhsBand = Self.supportSortBand(lhs.support)
						let rhsBand = Self.supportSortBand(rhs.support)
						if lhsBand != rhsBand { return lhsBand < rhsBand }
						if lhs.downloads != rhs.downloads { return lhs.downloads > rhs.downloads }
						return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
					}
				self.errorMessage = outcome.didSucceed ? nil : L10n.Catalog.Error.message
				self.isLoading = false
			} catch is CancellationError {
				return
			} catch {
				guard let self, self.selectedProviderIDs == selectedProviderIDsSnapshot else { return }
				self.results = []
				self.errorMessage = L10n.Catalog.Error.message
				self.isLoading = false
			}
		}
	}

	func toggleProvider(id: String) {
		guard providerDescriptors.first(where: { $0.id == id })?.isSearchable == true else { return }
		if selectedProviderIDs.contains(id) {
			guard selectedProviderIDs.count > 1 else { return }
			selectedProviderIDs.remove(id)
			if resultProviderFilterID == id {
				resultProviderFilterID = nil
			}
		} else {
			selectedProviderIDs.insert(id)
		}
		searchCurrentQuery()
	}

	func filterResults(to providerID: String?) {
		guard providerID == nil || selectedProviderIDs.contains(providerID ?? "") else { return }
		resultProviderFilterID = providerID
	}

	var hasActiveFilters: Bool {
		selectedTasks.isEmpty == false || selectedFamilies.isEmpty == false
	}

	func toggleTask(_ task: CatalogTask) {
		if selectedTasks.contains(task) {
			selectedTasks.remove(task)
		} else {
			selectedTasks.insert(task)
		}
		searchCurrentQuery()
	}

	func toggleFamily(_ family: CatalogFamilyFilter) {
		if selectedFamilies.contains(family) {
			selectedFamilies.remove(family)
		} else {
			selectedFamilies.insert(family)
		}
		searchCurrentQuery()
	}

	func clearFilters() {
		selectedTasks.removeAll()
		selectedFamilies.removeAll()
		searchCurrentQuery()
	}

	func providerName(for providerID: String) -> String {
		providerDescriptors.first(where: { $0.id == providerID })?.displayName ?? providerID
	}

	var searchableProviderDescriptors: [CatalogProviderDescriptor] {
		providerDescriptors.filter(\.isSearchable)
	}

	func cancelSearch() {
		searchTask?.cancel()
		searchTask = nil
		isLoading = false
	}

	func resolveFiles(for model: CatalogModel) async -> [CatalogFile]? {
		if let cachedFiles = resolvedFilesByModelID[modelKey(for: model)] {
			return cachedFiles
		}

		guard let provider = providersByID[model.providerId] else {
			errorMessage = L10n.Catalog.Error.message
			return nil
		}

		resolvingModelID = model.id
		defer { resolvingModelID = nil }
		do {
			let files = try await provider.resolveFiles(for: model)
			guard files.isEmpty == false else {
				errorMessage = L10n.Catalog.Error.unsupportedModel
				return nil
			}
			resolvedFilesByModelID[modelKey(for: model)] = files
			return files
		} catch is CancellationError {
			return nil
		} catch CatalogError.noInstallableArtifact {
			errorMessage = L10n.Catalog.Error.unsupportedModel
			return nil
		} catch {
			errorMessage = L10n.Catalog.Error.message
			return nil
		}
	}

	func resolvedArtifactURL(for model: CatalogModel) -> URL? {
		model.artifactURL ?? CatalogFile.primaryArtifact(in: resolvedFilesByModelID[modelKey(for: model)] ?? [])?.resolveURL
	}

	var visibleResults: [CatalogModel] {
		results.filter { model in
			matchesProviderFilter(model) && matchesTaskFilter(model) && matchesFamilyFilter(model)
		}
	}

	/// True when a search produced results but every one is hidden by the active task/family filters,
	/// so the UI can show a distinct "no matching models" message rather than the "no results" copy.
	var hasResultsHiddenByFilters: Bool {
		results.isEmpty == false && visibleResults.isEmpty
	}

	private func matchesProviderFilter(_ model: CatalogModel) -> Bool {
		guard let resultProviderFilterID else { return true }
		return model.providerId == resultProviderFilterID
	}

	private func matchesTaskFilter(_ model: CatalogModel) -> Bool {
		guard selectedTasks.isEmpty == false else { return true }
		return selectedTasks.contains(model.task)
	}

	private func matchesFamilyFilter(_ model: CatalogModel) -> Bool {
		guard selectedFamilies.isEmpty == false else { return true }
		let filter: CatalogFamilyFilter = model.family.map(CatalogFamilyFilter.family) ?? .other
		return selectedFamilies.contains(filter)
	}

	/// Two-band ordering for catalog results (AIA-0497). Band A (imports now or oracle-verified) ranks
	/// above band B (unverified, on-device conversion may fail). Native Core ML is NOT demoted below
	/// verified-convertible inside band A — both import reliably and stay ordered by downloads.
	private static func supportSortBand(_ support: CatalogSupport) -> Int {
		switch support {
		case .coreMLNative, .verifiedConvertible, .verifiedGeometryGenericLabels: return 0
		case .convertible: return 1
		}
	}

	var selectedProviderSummary: String {
		guard selectedProviderIDs.count != searchableProviderDescriptors.count else {
			return L10n.Catalog.Results.allSources
		}
		return searchableProviderDescriptors
			.filter { selectedProviderIDs.contains($0.id) }
			.map(\.displayName)
			.joined(separator: ", ")
	}

	private struct SearchOutcome {
		let models: [CatalogModel]
		let didSucceed: Bool
	}

	private func modelKey(for model: CatalogModel) -> String {
		"\(model.providerId):\(model.id)"
	}
}

#if DEBUG
private actor CatalogPreviewProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "preview", displayName: "Hugging Face")

	func search(query: String) async throws -> [CatalogModel] {
		[
			CatalogModel(
				id: "preview/Detector",
				providerId: descriptor.id,
				displayName: "Example detector",
				author: "Preview",
				downloads: 1_024,
				likes: 42,
				task: .objectDetection,
				format: .mlmodel,
				sizeBytes: 2_000_000
			)
		]
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] { [] }
}

@MainActor
private struct CatalogBrowsePreview: View {
	private let dataController: DataController
	@StateObject private var downloader: Downloader
	@StateObject private var deep: DeepState

	init() {
		let dataController = DataController(inMemory: true)
		self.dataController = dataController
		_downloader = StateObject(wrappedValue: Downloader(dataController: dataController))
		_deep = StateObject(wrappedValue: DeepState(dataController: dataController))
	}

	var body: some View {
		NavigationStack {
			CatalogBrowseView(
				searchManager: CatalogSearchManager(providers: [CatalogPreviewProvider()]),
				onImport: ImportHandler { _, _, _, _ in }
			)
		}
		.environment(\.managedObjectContext, dataController.container.viewContext)
		.environmentObject(downloader)
		.environmentObject(deep)
	}
}

#Preview("Results") {
	CatalogBrowsePreview()
}
#endif
