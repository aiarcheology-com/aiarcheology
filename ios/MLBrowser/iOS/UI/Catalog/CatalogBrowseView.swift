//
//  CatalogBrowseView.swift
//  AI Archeology
//
//  AIA-0413: catalog search and package-download presentation.
//

import SwiftUI

struct CatalogBrowseView: View {
	@Environment(\.dismiss) private var dismiss

	let onSelect: @MainActor (CatalogModel, [CatalogFile]) -> Void
	@StateObject private var searchManager: CatalogSearchManager

	init(providers: [any CatalogProvider], onSelect: @escaping @MainActor (CatalogModel, [CatalogFile]) -> Void) {
		self.onSelect = onSelect
		_searchManager = StateObject(wrappedValue: CatalogSearchManager(providers: providers))
	}

	var body: some View {
		NavigationStack {
			List {
				providerSection
				resultsSection
			}
			.listStyle(.insetGrouped)
			.navigationTitle(L10n.Catalog.title)
			.navigationBarTitleDisplayMode(.inline)
			.searchable(text: queryBinding, prompt: L10n.Catalog.Search.prompt)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(L10n.Common.dismiss) { dismiss() }
				}
			}
		}
		.onDisappear { searchManager.cancelSearch() }
	}
}

private extension CatalogBrowseView {
	var queryBinding: Binding<String> {
		Binding(
			get: { searchManager.query },
			set: { searchManager.updateQuery($0) }
		)
	}

	var providerSection: some View {
		Section(L10n.Catalog.provider) {
			Picker(L10n.Catalog.provider, selection: $searchManager.selectedProviderID) {
				ForEach(searchManager.providerDescriptors) { provider in
					Text(provider.displayName).tag(provider.id)
				}
			}
			.pickerStyle(.navigationLink)
			.testability(Testability.Picker.catalogProvider)
			.onChange(of: searchManager.selectedProviderID) {
				searchManager.searchCurrentQuery()
			}
		}
	}

	@ViewBuilder
	var resultsSection: some View {
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
			} else if searchManager.results.isEmpty {
				ContentUnavailableView(
					searchManager.query.isEmpty ? L10n.Catalog.Empty.title : L10n.Catalog.Empty.noResultsTitle,
					systemImage: "magnifyingglass",
					description: Text(searchManager.query.isEmpty ? L10n.Catalog.Empty.message : L10n.Catalog.Empty.noResultsMessage)
				)
			} else {
				ForEach(searchManager.results) { model in
					Button {
						select(model)
					} label: {
						CatalogResultRow(model: model, isResolving: searchManager.resolvingModelID == model.id)
					}
					.buttonStyle(.plain)
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
		Task {
			guard let files = await searchManager.resolveFiles(for: model) else { return }
			onSelect(model, files)
		}
	}
}

private struct CatalogResultRow: View {
	let model: CatalogModel
	let isResolving: Bool

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "cube.box")
				.foregroundStyle(.blue)
				.font(.title3)
				.frame(minWidth: 28)

			VStack(alignment: .leading, spacing: 5) {
				Text(model.displayName)
					.foregroundStyle(.primary)
					.lineLimit(2)
				Text(model.author)
					.font(.subheadline)
					.foregroundStyle(.secondary)

				HStack(spacing: 10) {
					Label(L10n.Catalog.Results.downloads(model.downloads), systemImage: "arrow.down.circle")
					Label(L10n.Catalog.Results.likes(model.likes), systemImage: "heart")
				}
				.font(.caption)
				.foregroundStyle(.secondary)

				HStack(spacing: 6) {
					catalogTag
					Text(L10n.Catalog.Results.coreML)
						.tagStyle()
					if let sizeBytes = model.sizeBytes {
						Text(Int(sizeBytes).formatBytesAsHumanReadable())
							.tagStyle()
					}
				}
			}

			Spacer(minLength: 0)
			if isResolving {
				ProgressView()
			} else {
				Image(systemName: "chevron.right")
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 3)
		.accessibilityElement(children: .combine)
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
	@Published var selectedProviderID: String
	@Published private(set) var results: [CatalogModel] = []
	@Published private(set) var isLoading = false
	@Published private(set) var errorMessage: String?
	@Published private(set) var resolvingModelID: String?

	let providerDescriptors: [CatalogProviderDescriptor]
	private let providersByID: [String: any CatalogProvider]
	private var searchTask: Task<Void, Never>?

	init(providers: [any CatalogProvider]) {
		let descriptors = providers.map(\.descriptor)
		self.providerDescriptors = descriptors
		self.providersByID = Dictionary(uniqueKeysWithValues: zip(descriptors.map(\.id), providers))
		self.selectedProviderID = descriptors.first?.id ?? ""
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
		let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmedQuery.count >= 2, let provider = providersByID[selectedProviderID] else {
			isLoading = false
			results = []
			errorMessage = nil
			return
		}

		isLoading = true
		errorMessage = nil
		let providerID = selectedProviderID
		searchTask = Task { [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(350))
				try Task.checkCancellation()
				let models = try await provider.search(query: trimmedQuery)
				guard let self, self.selectedProviderID == providerID, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery else {
					return
				}
				self.results = models
				self.isLoading = false
			} catch is CancellationError {
				return
			} catch {
				guard let self, self.selectedProviderID == providerID else { return }
				self.results = []
				self.errorMessage = L10n.Catalog.Error.message
				self.isLoading = false
			}
		}
	}

	func cancelSearch() {
		searchTask?.cancel()
		searchTask = nil
	}

	func resolveFiles(for model: CatalogModel) async -> [CatalogFile]? {
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
}

struct CatalogPackageDownloadView: View {
	@Environment(\.dismiss) private var dismiss

	let onFinished: @MainActor (URL) -> Void
	@StateObject private var downloadManager: CatalogPackageDownloadManager

	init(
		files: [CatalogFile],
		downloader: CatalogPackageDownloader,
		onFinished: @escaping @MainActor (URL) -> Void
	) {
		self.onFinished = onFinished
		_downloadManager = StateObject(
			wrappedValue: CatalogPackageDownloadManager(files: files, downloader: downloader)
		)
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				ProgressView(value: downloadManager.progress.fractionCompleted)
					.progressViewStyle(.linear)
					.testability(Testability.ProgressView.catalogPackageDownload)

				VStack(spacing: 8) {
					Text(L10n.Catalog.Download.title)
						.font(.headline)
					Text(L10n.Catalog.Download.progress(downloadManager.progress.completedFileCount, downloadManager.progress.totalFileCount))
						.foregroundStyle(.secondary)
					if downloadManager.progress.downloadedBytes > 0 {
						Text(Int(downloadManager.progress.downloadedBytes).formatBytesAsHumanReadable())
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Spacer()

				Button(L10n.Common.cancel, role: .cancel) {
					downloadManager.cancel()
					dismiss()
				}
				.testability(Testability.Button.catalogPackageCancel)
			}
			.padding(24)
			.navigationTitle(L10n.Catalog.title)
			.navigationBarTitleDisplayMode(.inline)
		}
		.onAppear {
			downloadManager.start(onFinished: onFinished)
		}
		.onDisappear { downloadManager.cancel() }
		.alert(L10n.Catalog.Error.title, isPresented: $downloadManager.isShowingError) {
			Button(L10n.Common.ok, role: .cancel) { dismiss() }
		} message: {
			Text(L10n.Catalog.Download.error)
		}
	}
}

@MainActor
final class CatalogPackageDownloadManager: ObservableObject {
	@Published private(set) var progress: CatalogPackageDownloadProgress
	@Published var isShowingError = false

	private let files: [CatalogFile]
	private let downloader: CatalogPackageDownloader
	private var downloadTask: Task<Void, Never>?

	init(files: [CatalogFile], downloader: CatalogPackageDownloader) {
		self.files = files
		self.downloader = downloader
		self.progress = CatalogPackageDownloadProgress(
			completedFileCount: 0,
			totalFileCount: files.count,
			downloadedBytes: 0,
			expectedBytes: nil
		)
	}

	deinit {
		downloadTask?.cancel()
	}

	func start(onFinished: @escaping @MainActor (URL) -> Void) {
		guard downloadTask == nil else { return }
		downloadTask = Task { [weak self] in
			guard let self else { return }
			do {
				let events = await self.downloader.events(for: self.files)
				for try await event in events {
					switch event {
					case .progress(let progress):
						self.progress = progress
					case .finished(let packageURL):
						onFinished(packageURL)
					}
				}
			} catch is CancellationError {
				return
			} catch {
				self.isShowingError = true
			}
		}
	}

	func cancel() {
		downloadTask?.cancel()
		downloadTask = nil
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

#Preview("Results") {
	CatalogBrowseView(providers: [CatalogPreviewProvider()]) { _, _ in }
}
#endif
