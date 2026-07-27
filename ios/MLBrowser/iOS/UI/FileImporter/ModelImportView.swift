//
//  ModelImportView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog
import NativeModelConverter

/// View for importing ML models either from local files or remote URLs.
///
/// Provides educational content about supported model types.
struct ModelImportView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc
	@EnvironmentObject private var deep: DeepState
	@EnvironmentObject private var downloader: Downloader
	/// Observed directly (not via `AppState`) so a remote flag flip re-renders this view:
	/// a nested ObservableObject does not republish through its parent (AIA-0350).
	@EnvironmentObject private var featureFlags: FeatureFlagsState
	@EnvironmentObject private var analytics: AnalyticsState

	/// Called with the new configuration's id after **every** successful import, so the presenter
	/// can auto-open the model's settings for the user to confirm its type when `needsReview` is
	/// true (AIA-0402). No imported model runs on an unconfirmed type — the app can't verify what a
	/// model actually does.
	///
	/// It fires on success regardless of `needsReview` (AIA-0117): the presenter also treats a
	/// completed import as a winning moment, and a converted non-CoreML package — the case most
	/// likely to arrive without a parseable type — must not be excluded from that.
	var onImported: (_ id: UUID, _ needsReview: Bool) -> Void = { _, _ in }
	let catalogProviders: [any CatalogProvider]
	/// Shared for the running app session so closing and reopening the catalog keeps its search.
	private let catalogSearchManager: CatalogSearchManager

	@StateObject private var acquisitionCoordinator = ModelAcquisitionCoordinator(
		allowedTypes: [
			// The app-exported package UTI (conforms to com.apple.package) so the Files picker treats
			// an .aiagraph directory as one selectable item instead of a browsable folder.
			UTType("com.aiarcheology.native-model-graph"),
			UTType(filenameExtension: "aiagraph"),
			UTType("com.apple.coreml.mlmodel"),
			UTType("com.apple.coreml.mlpackage"),
			UTType(filenameExtension: "mlmodel"),
			UTType(filenameExtension: "mlpackage"),
			UTType(filenameExtension: "mlmodelc"),
			// Self-contained ONNX models the app converts to Core ML on-device. The imported UTI
			// (declared in Info.plist) makes the Files picker surface `.onnx` reliably; the
			// extension-derived type is a fallback if the declaration is unavailable.
			UTType("com.aiarcheology.onnx-model"),
			UTType(filenameExtension: "onnx")
		].compactMap { $0 }
	)
	
	/// Holds remote import data until the sheet finishes dismissing
	@State private var pendingRemoteImport: (url: URL, id: UUID, downloadUrl: URL, provider: ModelProvider)?
	
	/// Loading state during model validation
	@State private var isLoading = false
	/// Phase-local progress from a native `.aiagraph` conversion, if this import needs one.
	@State private var nativeConversionProgress: NativeModelConversionProgress?
	/// The app-owned report is retained beside a converted or staged native package.
	@State private var nativeConversionReport: NativeModelConversionImportReport?
	/// The report currently selected for the user-visible log sheet.
	@State private var presentedNativeConversionReport: NativeModelConversionImportReport?
	/// An interrupted transaction discovered in the app sandbox.
	@State private var interruptedNativeConversion: NativeModelConversionImportReport?
	/// The import task can be cancelled only at package-defined cooperative checkpoints.
	@State private var activeImportTask: Task<Void, Never>?
	/// Identifies the one UI import allowed to apply asynchronous progress/report updates.
	///
	/// Package callbacks can be enqueued on the main actor immediately before a terminal update. This
	/// token prevents such late callbacks from repopulating SwiftUI state after completion or from a
	/// previous import appearing in the next import's UI.
	@State private var activeImportSessionID: UUID?
	/// A native package import waiting for the user's provenance-retention decision.
	@State private var originalRetentionRequest: ModelAcquisitionCoordinator.ImportRequest?
	/// The archive is deleted when the system share sheet completes or is dismissed.
	@State private var nativeModelSharePayload: ActivitySharePayload?
	@State private var isPreparingNativeModelExport = false
	
	/// Error to display in alert
	@State private var errorMessage: String?
	@State private var showErrorAlert = false
	
	/// Success state with imported model info
	@State private var importedModelInfo: ImportedModelInfo?

	init(
		onImported: @escaping (_ id: UUID, _ needsReview: Bool) -> Void = { _, _ in },
		catalogProviders: [any CatalogProvider],
		catalogSearchManager: CatalogSearchManager? = nil
	) {
		self.onImported = onImported
		self.catalogProviders = catalogProviders
		self.catalogSearchManager = catalogSearchManager ?? CatalogSearchManager(providers: catalogProviders)
	}
	
	var body: some View {
		// The presentation modifiers are grouped into separate functions so the SwiftUI view builder
		// is type-checked as several small expressions. As one continuous chain it exceeds the Swift
		// type-checker's limit and fails to compile.
		importReportPresentations(importRetentionDialogs(importAlerts(rootContent)))
			.presentationDetents([.large])
	}

	private var rootContent: some View {
		NavigationStack {
			contentList
				.navigationTitle(L10n.Import.title)
				.navigationBarTitleDisplayMode(.inline)
				.toolbar { toolbarContent }
				.navigationDestination(isPresented: $acquisitionCoordinator.isShowingCatalog) {
					CatalogBrowseView(
						searchManager: catalogSearchManager,
						onImport: ImportHandler { url, id, downloadURL, provider in
							handleCatalogRemoteImport(
								url: url,
								id: id,
								downloadURL: downloadURL,
								provider: provider
							)
						}
					)
				}
		}
		.overlay {
			if isLoading {
				loadingOverlay
			}
		}
		.fileImporter(
			isPresented: $acquisitionCoordinator.isShowingFileImporter,
			allowedContentTypes: acquisitionCoordinator.allowedTypes,
			allowsMultipleSelection: false,
			onCompletion: handleFileImportResult
		)
		.sheet(isPresented: $acquisitionCoordinator.isShowingDownloader, onDismiss: handleDownloaderDismiss) {
			remoteDownloaderSheet
		}
		.onChange(of: acquisitionCoordinator.pendingImport) { _, request in
			handlePendingImport(request)
		}
		.onAppear(perform: discoverInterruptedNativeConversion)
	}

	private func importAlerts(_ content: some View) -> some View {
		content
		.alert(L10n.Alert.Error.title, isPresented: $showErrorAlert) {
			if nativeConversionReport != nil {
				Button(L10n.Import.showConversionLog) {
					presentedNativeConversionReport = nativeConversionReport
				}
			}
			Button(L10n.Common.ok, role: .cancel) { }
		} message: {
			Text(errorMessage ?? "An unknown error occurred.")
		}
		.alert(importedModelInfo?.needsReview == true ? L10n.Import.confirmTypeTitle : L10n.Import.successTitle,
			   isPresented: .init(
				get: { importedModelInfo != nil },
				set: { if !$0 { importedModelInfo = nil } }
		)) {
			if nativeConversionReport != nil {
				Button(L10n.Import.showConversionLog) {
					presentedNativeConversionReport = nativeConversionReport
				}
			}
			Button(L10n.Common.ok) {
				let info = importedModelInfo
				importedModelInfo = nil
				// Only an unparsed-type model opens its settings for the user to pick a type; a
				// parsed (authoritative) type is trusted and locked, so its import just confirms
				// success. Hand the id to the presenter FIRST so its onDismiss can open the
				// settings sheet once this import sheet finishes dismissing (AIA-0402).
				if let info { onImported(info.id, info.needsReview) }
				dismiss()
			}
		} message: {
			Text(importSuccessMessage(for: importedModelInfo))
		}
	}

	private func importSuccessMessage(for info: ImportedModelInfo?) -> String {
		let base = info?.needsReview == true ? L10n.Import.typeConfirmation : L10n.Import.success
		guard let assumption = info?.nativeModelImportAssumption else { return base }
		return "\(base)\n\n\(inferredSemanticsMessage(for: assumption))"
	}

	private func inferredSemanticsMessage(for assumption: NativeModelImportAssumption) -> String {
		let labels: String
		switch assumption.labelProfile {
		case .imageNet1K:
			labels = L10n.Import.inferredLabelsImageNet
		case .pascalVOC:
			labels = L10n.Import.inferredLabelsPascalVoc
		case .genericClassIndex:
			labels = L10n.Import.inferredLabelsGeneric
		case .sourceMetadata:
			// Source-metadata labels cannot form an assumption by construction. Keep the UI safe if a
			// future contract extends the parser before this view is updated.
			assertionFailure("Source-metadata labels should not produce an import assumption.")
			labels = L10n.Import.inferredLabelsGeneric
		}
		let preprocessing: String
		switch assumption.preprocessingProfile {
		case .imageNetRGB:
			preprocessing = L10n.Import.inferredPreprocessingImageNetRgb
		case .rgbZeroToOne:
			preprocessing = L10n.Import.inferredPreprocessingRgbZeroToOne
		case .identityRGB:
			preprocessing = L10n.Import.inferredPreprocessingEmbedded
		case .none:
			preprocessing = L10n.Import.inferredPreprocessingNone
		}
		return L10n.Import.inferredSemantics(labels, preprocessing)
	}

	private func importRetentionDialogs(_ content: some View) -> some View {
		content
		.confirmationDialog(
			L10n.Import.keepOriginalTitle,
			isPresented: Binding(
				get: { originalRetentionRequest != nil },
				set: { if !$0 { originalRetentionRequest = nil } }
			),
			titleVisibility: .visible,
			presenting: originalRetentionRequest
		) { request in
			Button(L10n.Import.keepOriginal) {
				startImport(request, retainingOriginalNativePackage: true)
			}
			Button(L10n.Import.convertOnly) {
				startImport(request, retainingOriginalNativePackage: false)
			}
		} message: { _ in
			Text(L10n.Import.keepOriginalMessage)
		}
		.onChange(of: originalRetentionRequest) { previous, current in
			guard previous != nil, current == nil, !isLoading else { return }
			// Dismissing the choice is a cancelled import. Nothing has been copied yet, and a remote
			// download remains available to import again.
			acquisitionCoordinator.markImportHandled()
		}
		.confirmationDialog(
			L10n.Import.resumeConversionTitle,
			isPresented: Binding(
				get: { interruptedNativeConversion != nil },
				set: { if !$0 { interruptedNativeConversion = nil } }
			),
			titleVisibility: .visible,
			presenting: interruptedNativeConversion
		) { report in
			Button(L10n.Import.resumeConversion) {
				resumeInterruptedNativeConversion(report)
			}
			Button(L10n.Import.showConversionLog) {
				presentedNativeConversionReport = report
			}
			Button(L10n.Import.discardConversion, role: .destructive) {
				discardInterruptedNativeConversion(report)
			}
		} message: { _ in
			Text(L10n.Import.resumeConversionMessage)
		}
	}

	private func importReportPresentations(_ content: some View) -> some View {
		content
		.sheet(item: $presentedNativeConversionReport) { report in
			NativeModelConversionReportView(
				report: report,
				isPreparingExport: isPreparingNativeModelExport,
				onExport: { exportConvertedModel(report) }
			)
		}
		.activityShareSheet($nativeModelSharePayload)
	}

	// MARK: - Content
	
	private var contentList: some View {
		List {
			importButtonsSection
			instructionsSection
			documentationSection
		}
		.listStyle(.insetGrouped)
	}
	
	// MARK: - Import Buttons Section
	
	private var importButtonsSection: some View {
		Section {
			Button {
				acquisitionCoordinator.beginLocalImport()
			} label: {
				Label {
					VStack(alignment: .leading, spacing: 4) {
						Text(L10n.Import.fromFiles)
							.foregroundStyle(Color(.label))
						Text(L10n.Import.fromFilesHint)
							.font(.caption)
							.foregroundStyle(Color(.secondaryLabel))
					}
				} icon: {
					Image(systemName: "folder")
						.font(.title2)
						.foregroundStyle(.blue)
				}
			}
			.buttonStyle(.plain)
			.testability(Testability.Button.newConfigurationPickDocument)

			Button {
				acquisitionCoordinator.beginRemoteImport()
			} label: {
				Label {
					VStack(alignment: .leading, spacing: 4) {
						Text(L10n.Import.fromURL)
							.foregroundStyle(Color(.label))
						Text(L10n.Import.fromURLHint)
							.font(.caption)
							.foregroundStyle(Color(.secondaryLabel))
					}
				} icon: {
					Image(systemName: "globe")
						.font(.title2)
						.foregroundStyle(.blue)
				}
			}
			.buttonStyle(.plain)
			.testability(Testability.Button.newConfigurationPickUrl)

			if featureFlags.snapshot.isModelCatalogEnabled {
				Button {
					acquisitionCoordinator.beginCatalogBrowse()
				} label: {
					Label {
						VStack(alignment: .leading, spacing: 4) {
							Text(L10n.Catalog.title)
								.foregroundStyle(Color(.label))
							Text(L10n.Catalog.Empty.message)
								.font(.caption)
								.foregroundStyle(Color(.secondaryLabel))
						}
					} icon: {
						Image(systemName: "square.grid.2x2")
							.font(.title2)
							.foregroundStyle(.blue)
					}
				}
				.buttonStyle(.plain)
				.testability(Testability.Button.newConfigurationOpenCatalog)
			}
		}
	}
	
	// MARK: - Instructions Section
	
	private var instructionsSection: some View {
		Section {
			Text(L10n.Import.supportedModelsInfo)
				.font(.subheadline)
				.foregroundStyle(Color(.secondaryLabel))
		} header: {
			Text(L10n.Import.supportedModels)
		}
	}
	
	// MARK: - Documentation Section
	
    // swiftlint:disable force_unwrapping
    private var documentationSection: some View {
        Section {
            Link(destination: URL(string: "https://developer.apple.com/documentation/createml")!) {
                Label(L10n.Import.appleDocumentation, systemImage: "book")
            }
            .testability(Testability.Link.newConfigurationAppleDocumentation)

            Link(destination: URL(string: "https://developer.apple.com/videos/play/wwdc2020/10153/")!) {
                Label(L10n.Import.wwdcCoreML, systemImage: "play.rectangle")
            }
            .testability(Testability.Link.newConfigurationCoreMLConverters)
        } header: {
            Text(L10n.Import.learnMore)
        }
    }
    // swiftlint:enable force_unwrapping
	
	// MARK: - Toolbar
	
	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .topBarTrailing) {
			Button(L10n.Common.dismiss) {
				dismiss()
			}
			.tint(.blue)
		}
	}
	
	// MARK: - Loading Overlay
	
	private var loadingOverlay: some View {
		ZStack {
			Color.black.opacity(0.3)
				.ignoresSafeArea()

			Group {
				if let progress = nativeConversionProgress, let fraction = progress.fractionCompleted {
					VStack(alignment: .leading, spacing: 8) {
						ProgressView(value: fraction) {
							Text(conversionProgressTitle(progress))
						} currentValueLabel: {
							Text("\(progress.completedUnitCount) / \(progress.totalUnitCount)")
						}
						if let memoryUsage = progress.processMemoryUsage {
							conversionMemoryUsageView(memoryUsage)
						}
					}
				} else {
					VStack(alignment: .leading, spacing: 8) {
						ProgressView {
							Text(nativeConversionProgress.map(conversionProgressTitle) ?? L10n.Import.validating)
						}
						if let memoryUsage = nativeConversionProgress?.processMemoryUsage {
							conversionMemoryUsageView(memoryUsage)
						}
					}
				}
			}
			.padding(24)
			.overlay(alignment: .bottomTrailing) {
				if activeImportTask != nil {
					Button(L10n.Common.cancel) {
						activeImportTask?.cancel()
					}
					.buttonStyle(.bordered)
					.padding(12)
				}
			}
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
		}
	}

	@ViewBuilder
	private func conversionMemoryUsageView(_ usage: NativeModelConversionProcessMemoryUsage) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("\(L10n.Import.conversionProcessMemory): \(formattedByteCount(usage.currentProcessFootprintByteCount))")
			Text("\(L10n.Import.conversionObservedPeakIncrease): \(formattedByteCount(usage.observedPeakIncreaseByteCount))")
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.accessibilityElement(children: .combine)
	}

	private func formattedByteCount(_ byteCount: UInt64) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .memory)
	}

	private func conversionProgressTitle(_ progress: NativeModelConversionProgress) -> String {
		progress.phase == .waitingForExclusiveAccess
			? L10n.Import.conversionWaitingForExclusiveAccess
			: L10n.Import.validating
	}
	
	// MARK: - Remote Downloader Sheet
	
	private var remoteDownloaderSheet: some View {
		NavigationStack {
			DownloaderView(
				onImport: ImportHandler { url, id, downloadUrl, provider in
					handleRemoteImport(url: url, id: id, downloadUrl: downloadUrl, provider: provider)
				}
			)
			.environmentObject(downloader)
			.environmentObject(deep)
		}
	}

	// MARK: - Event Handlers
	
	private func handleRemoteImport(url: URL, id: UUID, downloadUrl: URL, provider: ModelProvider) {
		pendingRemoteImport = (url, id, downloadUrl, provider)
		acquisitionCoordinator.isShowingDownloader = false
	}

	private func handleCatalogRemoteImport(url: URL, id: UUID, downloadURL: URL, provider: ModelProvider) {
		pendingRemoteImport = (url, id, downloadURL, provider)
		handleDownloaderDismiss()
	}
	
	private func handleDownloaderDismiss() {
		guard let pending = pendingRemoteImport else { return }
		pendingRemoteImport = nil
		acquisitionCoordinator.completeRemoteImport(
			url: pending.url,
			configurationId: pending.id,
			downloadUrl: pending.downloadUrl,
			provider: pending.provider
		)
	}

	private func handleFileImportResult(_ result: Result<[URL], Error>) {
		switch result {
		case .success(let urls):
			if let url = urls.first {
				acquisitionCoordinator.completeLocalImport(url: url, provider: NoopProvider())
			}
		case .failure(let error):
			errorMessage = error.localizedDescription
			showErrorAlert = true
		}
	}
	
	private func handlePendingImport(_ request: ModelAcquisitionCoordinator.ImportRequest?) {
		guard let request else { return }
		if request.url.pathExtension.lowercased() == "aiagraph" {
			originalRetentionRequest = request
			return
		}
		startImport(request, retainingOriginalNativePackage: false)
	}

	private func discoverInterruptedNativeConversion() {
		guard activeImportTask == nil,
			interruptedNativeConversion == nil,
			let documentsDirectory = FileManager.default.documentDirectory
		else {
			return
		}
		let configurationsDirectory = documentsDirectory.appendingPathComponent("Configurations", isDirectory: true)
		guard var report = NativeModelConversionImportReport
			.recoverableReports(in: configurationsDirectory)
			.first
		else {
			return
		}
		if report.markInterruptedIfIncomplete(),
			let configurationDirectory = FileManager.deepConfigurationDirectory(id: report.configurationID) {
			try? report.write(in: configurationDirectory)
		}
		interruptedNativeConversion = report
	}

	private func resumeInterruptedNativeConversion(_ report: NativeModelConversionImportReport) {
		interruptedNativeConversion = nil
		guard let configurationDirectory = FileManager.deepConfigurationDirectory(id: report.configurationID) else {
			errorMessage = NativeModelConversionImportReportError.invalidReport.localizedDescription
			showErrorAlert = true
			return
		}
		let request = ModelAcquisitionCoordinator.ImportRequest(
			url: report.sourcePackageURL(in: configurationDirectory),
			downloadUrl: DownloadItem.select(report.configurationID, in: moc)?.url,
			configurationId: report.configurationID,
			provider: report.wasRemoteImport ? downloader : NoopProvider()
		)
		startImport(
			request,
			retainingOriginalNativePackage: report.retainOriginalPackage,
			existingNativeReport: report
		)
	}

	private func discardInterruptedNativeConversion(_ report: NativeModelConversionImportReport) {
		interruptedNativeConversion = nil
		guard let configurationDirectory = FileManager.deepConfigurationDirectory(id: report.configurationID) else {
			return
		}
		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: true
		)
		try? FileManager.default.removeItem(at: NativeModelConversionImportReport.reportURL(in: configurationDirectory))
		if nativeConversionReport?.configurationID == report.configurationID {
			nativeConversionReport = nil
		}
	}

	private func exportConvertedModel(_ report: NativeModelConversionImportReport) {
		guard report.state == .registered, !isPreparingNativeModelExport else { return }
		guard let configurationDirectory = FileManager.deepConfigurationDirectory(id: report.configurationID) else {
			errorMessage = NativeModelConversionImportReportError.invalidReport.localizedDescription
			showErrorAlert = true
			return
		}
		isPreparingNativeModelExport = true
		Task {
			do {
				let archiveURL = try await Task.detached(priority: .userInitiated) {
					try NativeModelConversionExporter.makeZip(
						report: report,
						configurationDirectory: configurationDirectory
					)
				}.value
				nativeModelSharePayload = ActivitySharePayload(
					items: [archiveURL],
					completion: { NativeModelConversionExporter.removeExportArchive(at: archiveURL) }
				)
			} catch {
				LoggingPolicy.error("Failed to export converted model", error: error, logger: .storage)
				errorMessage = error.localizedDescription
				showErrorAlert = true
			}
			isPreparingNativeModelExport = false
		}
	}

	private func startImport(
		_ request: ModelAcquisitionCoordinator.ImportRequest,
		retainingOriginalNativePackage: Bool,
		existingNativeReport: NativeModelConversionImportReport? = nil
	) {
		guard activeImportTask == nil else { return }
		let importSessionID = UUID()
		activeImportSessionID = importSessionID
		isLoading = true
		nativeConversionReport = existingNativeReport
		nativeConversionProgress = existingNativeReport?.lastProgress
		let reportObserver: @Sendable (NativeModelConversionImportReport) -> Void = { report in
			Task { @MainActor in
				guard activeImportSessionID == importSessionID else { return }
				nativeConversionReport = report
			}
		}

		activeImportTask = Task {
			do {
				let info = try await importConfiguration(
					NativeModelImportRequest(
						sourceURL: request.url,
						downloadURL: request.downloadUrl,
						configurationID: request.configurationId,
						importSessionID: importSessionID,
						provider: request.provider,
						retainingOriginalNativePackage: retainingOriginalNativePackage,
						existingNativeReport: existingNativeReport,
						reportObserver: reportObserver
					)
				)
				await MainActor.run {
					guard activeImportSessionID == importSessionID else { return }
					importedModelInfo = info
					clearActiveImportState(for: importSessionID)
					acquisitionCoordinator.markImportHandled()
				}
			} catch {
				await MainActor.run {
					guard activeImportSessionID == importSessionID else { return }
					if !isNativeConversionCancellation(error) {
						request.provider.result(.importFailed, id: request.configurationId)
						errorMessage = error.localizedDescription
						showErrorAlert = true
					}
					clearActiveImportState(for: importSessionID)
					acquisitionCoordinator.markImportHandled()
				}
			}
		}
	}

	@MainActor
	private func clearActiveImportState(for importSessionID: UUID) {
		guard activeImportSessionID == importSessionID else { return }
		isLoading = false
		nativeConversionProgress = nil
		activeImportTask = nil
		activeImportSessionID = nil
	}

	/// Import and validate a model configuration
	///
	/// This method performs expensive operations (file copy, model compilation/loading)
	/// off the MainActor for better UI responsiveness.
	///
	/// - Returns: Info about the imported model for display in success alert
	@discardableResult
	private func importConfiguration(
		_ request: NativeModelImportRequest
	) async throws -> ImportedModelInfo {
		// Phase 1: File operations and model loading (off MainActor)
		// Copy file to Documents and load/validate model metadata
		let work = try await performOffMainActorWork(request)

		// Phase 2: Core Data operations (on MainActor)
		do {
			try Task.checkCancellation()
			let info = try await MainActor.run {
				try createAndSaveConfiguration(
					modelURL: work.modelURL,
					preferredModelName: work.preferredModelName,
					downloadUrl: request.downloadURL,
					id: request.configurationID,
					extractedInfo: work.extractedInfo,
					provider: request.provider
				)
			}
			if let reportStore = work.reportStore {
				// The Core Data row is already committed and points at the converted model. Persisting
				// the final `.registered` checkpoint must not be able to throw into the catch below,
				// which would delete that model as a "transient" artifact and surface a spurious import
				// failure. A report left at `.emitted` is finalized by interruption recovery instead.
				try? await reportStore.transition(to: .registered)
				let report = await reportStore.snapshot()
				if !report.retainOriginalPackage {
					try? FileManager.default.removeItem(at: report.sourcePackageURL(in: work.configurationDirectory))
				}
				request.reportObserver(report)
			}
			return info
		} catch {
			if let reportStore = work.reportStore {
				await recordNativeImportFailure(
					error,
					reportStore: reportStore,
					configurationDirectory: work.configurationDirectory,
					reportObserver: request.reportObserver
				)
			}
			throw error
		}
	}

	/// Performs file copy and model loading off the MainActor.
	///
	/// Uses `Task.detached` to ensure file I/O runs on a background executor,
	/// not inherited from the MainActor-isolated call site.
	///
	/// - Returns: Tuple of (stored model URL, extracted metadata)
	private func performOffMainActorWork(
		_ request: NativeModelImportRequest
	) async throws -> NativeModelImportWork {
		// Copy the source into the per-configuration directory in a detached task. Task.detached
		// doesn't inherit actor context, unlike plain Task { }, so document-provider I/O cannot block
		// SwiftUI. A native graph package is then verified and converted before the normal Core ML
		// loader sees it.
		let sourceURL = request.sourceURL
		let configurationID = request.configurationID
		let downloadURL = request.downloadURL
		let storedURL = try await Task.detached(priority: .userInitiated) {
			let stored = try FileManager.storeModelInDocuments(from: sourceURL, configurationId: configurationID)
			return Self.restoringNativeConvertibleExtension(of: stored, from: downloadURL)
		}.value
		let configurationDirectory = storedURL.deletingLastPathComponent()
		let reportStore: NativeModelConversionImportReportStore?
		if Self.nativeConvertibleExtensions.contains(storedURL.pathExtension.lowercased()) {
			let report: NativeModelConversionImportReport
			if let existingNativeReport = request.existingNativeReport {
				guard existingNativeReport.configurationID == configurationID,
					existingNativeReport.sourcePackageFilename == storedURL.lastPathComponent
				else {
					throw NativeModelConversionImportReportError.invalidReport
				}
				report = existingNativeReport
			} else {
				report = try NativeModelConversionImportReport(
					configurationID: configurationID,
					sourcePackageFilename: storedURL.lastPathComponent,
					retainOriginalPackage: request.retainingOriginalNativePackage,
					wasRemoteImport: request.downloadURL != nil
				)
				try report.write(in: configurationDirectory)
			}
			reportStore = NativeModelConversionImportReportStore(
				report: report,
				configurationDirectory: configurationDirectory
			)
			request.reportObserver(report)
		} else {
			reportStore = nil
		}
		do {
			try Task.checkCancellation()
		} catch {
			if let reportStore {
				await recordNativeImportFailure(
					error,
					reportStore: reportStore,
					configurationDirectory: configurationDirectory,
					reportObserver: request.reportObserver
				)
			}
			throw error
		}

		let modelURL: URL
		if let reportStore {
				modelURL = try await convertNativeGraphPackageIfNeeded(
					NativeGraphConversionRequest(
						storedURL: storedURL,
						importSessionID: request.importSessionID,
						originalModelFilename: sourceURL.lastPathComponent,
						originalModelURL: request.downloadURL?.absoluteString,
						reportStore: reportStore,
						configurationDirectory: configurationDirectory,
						reportObserver: request.reportObserver
					)
				)
		} else {
			modelURL = storedURL
		}

		// Load and validate the model using ModelLoadingService (actor, so off MainActor)
		let service = ModelLoadingService()
		let extractedInfo: ExtractedModelInfo
		do {
			extractedInfo = try await service.loadAndExtractMetadata(from: modelURL, demo: false)
			try Task.checkCancellation()
		} catch {
			if let reportStore {
				await recordNativeImportFailure(
					error,
					reportStore: reportStore,
					configurationDirectory: configurationDirectory,
					reportObserver: request.reportObserver
				)
			}
			throw error
		}

		// A converted native source is stored as `converted.mlmodel`, whose name is meaningless to the
		// user, and a package may carry no model description. Keep the stored source name (which, for a
		// URL download, is the restored original filename) so the configuration is titled after what
		// the user actually imported (e.g. "MobileNetV2").
		let preferredModelName = reportStore != nil ? storedURL.lastPathComponent.fileName : nil
		return NativeModelImportWork(
			modelURL: modelURL,
			preferredModelName: preferredModelName,
			extractedInfo: extractedInfo,
			configurationDirectory: configurationDirectory,
			reportStore: reportStore
		)
	}

	/// Source extensions the app converts to Core ML on-device before the normal loader runs: the
	/// auditable native package (`.aiagraph`) and self-contained ONNX (`.onnx`). Both share the same
	/// conversion report machinery (progress, cancellation, log sheet, export).
	private static let nativeConvertibleExtensions: Set<String> = ["aiagraph", "onnx"]

	/// A model downloaded from a URL is stored under the URLSession temporary name, which drops the
	/// original extension. When the download URL names a native-convertible format but the stored file
	/// no longer carries that extension, restore the original filename so the on-device converter is
	/// selected. Core ML files (`.mlmodel`/`.mlpackage`) and files that already carry a convertible
	/// extension (Files/catalog imports) are returned untouched.
	nonisolated private static func restoringNativeConvertibleExtension(of storedURL: URL, from downloadURL: URL?) -> URL {
		let storedExtension = storedURL.pathExtension.lowercased()
		guard !nativeConvertibleExtensions.contains(storedExtension),
			let downloadURL,
			nativeConvertibleExtensions.contains(downloadURL.pathExtension.lowercased())
		else {
			return storedURL
		}
		let restoredURL = storedURL.deletingLastPathComponent().appendingPathComponent(downloadURL.lastPathComponent)
		guard restoredURL != storedURL else { return storedURL }
		do {
			if FileManager.default.fileExists(atPath: restoredURL.path) {
				try FileManager.default.removeItem(at: restoredURL)
			}
			try FileManager.default.moveItem(at: storedURL, to: restoredURL)
			return restoredURL
		} catch {
			LoggingPolicy.warning("Could not restore native model extension for downloaded file", logger: .storage)
			return storedURL
		}
	}

	/// Converts a verified native source (`.aiagraph` package or `.onnx` file) to a Core ML model
	/// beside the copied original.
	///
	/// The source and report are never removed while conversion is active. A process interruption
	/// therefore leaves a recoverable report and the source in the app sandbox. After Core Data
	/// registration succeeds, the original is removed only when the user chose Convert Only.
	private func convertNativeGraphPackageIfNeeded(
		_ request: NativeGraphConversionRequest
	) async throws -> URL {
		let storedURL = request.storedURL
		let sourceExtension = storedURL.pathExtension.lowercased()
		guard Self.nativeConvertibleExtensions.contains(sourceExtension) else {
			return storedURL
		}

		let report = await request.reportStore.snapshot()
		let generatedModelURL = report.convertedModelURL(in: request.configurationDirectory)
		if report.state == .emitted, FileManager.default.fileExists(atPath: generatedModelURL.path) {
			return generatedModelURL
		}
		do {
			try await request.reportStore.transition(to: .converting)
			request.reportObserver(await request.reportStore.snapshot())
			let converter = NativeModelConverter()
			let reportProgress: NativeModelConversionProgressHandler = { progress in
				Task {
					await request.reportStore.record(progress: progress)
					request.reportObserver(await request.reportStore.snapshot())
				}
				Task { @MainActor in
					guard activeImportSessionID == request.importSessionID else { return }
					nativeConversionProgress = progress
				}
			}
			let conversionTask = Task.detached(priority: .userInitiated) {
				if sourceExtension == "onnx" {
					return try await converter.convert(
						onnx: storedURL,
						to: generatedModelURL,
						reporting: reportProgress
					)
				}
				return try await converter.convert(
					from: storedURL,
					to: generatedModelURL,
					sourceProvenance: NativeModelConversionSourceProvenance(
						originalModelFilename: request.originalModelFilename,
						originalModelURL: request.originalModelURL
					),
					reporting: reportProgress
				)
			}
			let metrics = try await withTaskCancellationHandler(
				operation: { try await conversionTask.value },
				onCancel: { conversionTask.cancel() }
			)
			try await request.reportStore.record(metrics: metrics)
			try await request.reportStore.transition(to: .emitted)
			request.reportObserver(await request.reportStore.snapshot())
			return generatedModelURL
		} catch {
			await recordNativeImportFailure(
				error,
				reportStore: request.reportStore,
				configurationDirectory: request.configurationDirectory,
				reportObserver: request.reportObserver
			)
			throw error
		}
	}

	private func recordNativeImportFailure(
		_ error: Error,
		reportStore: NativeModelConversionImportReportStore,
		configurationDirectory: URL,
		reportObserver: @escaping @Sendable (NativeModelConversionImportReport) -> Void
	) async {
		let diagnostic = nativeConversionDiagnostic(for: error)
		let isCancelled = isNativeConversionCancellation(error)
		let terminalState: NativeModelConversionImportState = isCancelled ? .cancelled : .failed
		try? await reportStore.transition(to: terminalState, diagnostic: diagnostic)
		let report = await reportStore.snapshot()
		// Cancellation and a normal error both finish this *attempt*. Never retain generated output
		// from an unregistered attempt: the source and report are the durable retry/support records.
		// A process termination is different—the process cannot run this cleanup, so recovery owns it.
		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: false
		)
		reportObserver(report)
	}

	private func nativeConversionDiagnostic(for error: Error) -> NativeModelConversionDiagnostic {
		if let error = error as? NativeModelConversionError {
			return error.diagnostic
		}
		if error is CancellationError {
			return NativeModelConversionDiagnostic(
				code: "cancelled",
				phase: .preparing,
				message: "Conversion was cancelled before the next safe checkpoint."
			)
		}
		return NativeModelConversionDiagnostic(
			code: "app.modelValidationOrRegistrationFailed",
			phase: .failed,
			message: "The emitted model could not be loaded, validated, or registered."
		)
	}

	private func isNativeConversionCancellation(_ error: Error) -> Bool {
		if error is CancellationError {
			return true
		}
		guard let conversionError = error as? NativeModelConversionError else {
			return false
		}
		if case .cancelled = conversionError {
			return true
		}
		return false
	}

	/// Creates and saves the Core Data configuration entity.
	/// Must be called on MainActor.
	@MainActor
	private func createAndSaveConfiguration(
		modelURL: URL,
		preferredModelName: String? = nil,
		downloadUrl: URL?,
		id: UUID,
		extractedInfo: ExtractedModelInfo,
		provider: ModelProvider
	) throws -> ImportedModelInfo {
		// A process can terminate after Core Data saves but before the report's final `registered`
		// checkpoint is written. Recovery must recognize the durable row and finalize the report,
		// rather than creating a second configuration with the same UUID.
		if let existing = DeepConfiguration.select(id, in: moc) {
			provider.result(.importSucceeded, id: id)
			return ImportedModelInfo(
				id: id,
				needsReview: !existing.modelTypeParsed,
				nativeModelImportAssumption: extractedInfo.nativeModelImportAssumption
			)
		}

		// Create a new configuration entity
		let configuration = DeepConfiguration.create(in: moc)

		// Populate configuration from extracted metadata
		configuration.entityId = id
		let description = extractedInfo.modelDescription
		// For a converted native package, title the configuration after the original source (e.g.
		// "MobileNetV2") rather than the "converted.mlmodel" artifact name or the converter's verbose
		// technical description. Direct model imports keep their embedded description or filename.
		configuration.modelDescription = preferredModelName
			?? (description.isNotBlank ? description : modelURL.lastPathComponent.fileName)
		configuration.modelVersion = extractedInfo.modelVersion
		configuration.author = extractedInfo.author
		configuration.license = extractedInfo.license
		configuration.creationDate_ = extractedInfo.creationDateString?.toDate(.createMl)
		configuration.modelType = extractedInfo.task
		configuration.modelTypeParsed = extractedInfo.typeWasParsed
		configuration.phaseOutTime = 2
		configuration.selectedSymbol = .circle

		guard let relativePath = try? modelURL.relativePath(from: DeepConfiguration.rootDirectory) else {
			moc.delete(configuration)
			LoggingPolicy.error("Failed to compute relative path for model file", logger: .configuration)
			throw ImportError.invalidPath
		}

		configuration.file_ = relativePath
		configuration.downloadURL = downloadUrl
		configuration.catalogSource = DownloadItem.select(id, in: moc)?.catalogSource
		configuration.enabled = false
		configuration.transition(to: .draft)

		// Validate
		do {
			try configuration.validateForInsert()
			configuration.lifeCycle = .ready
		} catch {
			configuration.lifeCycle = .draft
		}

		// Save or report failure
		if configuration.lifeCycle == .ready {
			deep.saveConfigurations()
			provider.result(.importSucceeded, id: id)
			let source: ModelAcquisitionSource
			if downloadUrl == nil {
				source = .fileImport
			} else if configuration.catalogSource != nil {
				source = .catalog
			} else {
				source = .directDownload
			}
			analytics.track(.modelImported(source: source))

			return ImportedModelInfo(
				id: id,
				needsReview: !extractedInfo.typeWasParsed,
				nativeModelImportAssumption: extractedInfo.nativeModelImportAssumption
			)
		} else {
			moc.delete(configuration)
			provider.result(.importFailed, id: id)
			throw ImportError.validationFailed
		}
	}
}

// MARK: - Imported Model Info

/// The host workflow's non-UI result. It keeps the app-owned report store separate from the
/// package's conversion API and lets registration finalize the transaction only after Core Data
/// succeeds.
private struct NativeModelImportWork {
	let modelURL: URL
	/// The user-facing name to prefer for the configuration (the original source name for a converted
	/// native package, `nil` for a direct model import whose own filename is already meaningful).
	let preferredModelName: String?
	let extractedInfo: ExtractedModelInfo
	let configurationDirectory: URL
	let reportStore: NativeModelConversionImportReportStore?
}

/// Immutable input to one import attempt. It keeps the SwiftUI orchestration and the background
/// file/conversion work on the same transaction values without letting the package depend on UI.
private struct NativeModelImportRequest {
	let sourceURL: URL
	let downloadURL: URL?
	let configurationID: UUID
	let importSessionID: UUID
	let provider: ModelProvider
	let retainingOriginalNativePackage: Bool
	let existingNativeReport: NativeModelConversionImportReport?
	let reportObserver: @Sendable (NativeModelConversionImportReport) -> Void
}

/// The native-only portion of an import after the source has been staged into app-owned storage.
private struct NativeGraphConversionRequest {
	let storedURL: URL
	let importSessionID: UUID
	let originalModelFilename: String
	let originalModelURL: String?
	let reportStore: NativeModelConversionImportReportStore
	let configurationDirectory: URL
	let reportObserver: @Sendable (NativeModelConversionImportReport) -> Void
}

/// Identifies a just-imported model. `needsReview` is `true` when the parser couldn't determine the
/// type, so the presenter opens the model's settings for the user to pick one (AIA-0402).
private struct ImportedModelInfo {
	let id: UUID
	let needsReview: Bool
	let nativeModelImportAssumption: NativeModelImportAssumption?
}

// MARK: - Supporting Types

private enum ImportError: LocalizedError {
	case missingMetadata
	case invalidPath
	case validationFailed
	
	var errorDescription: String? {
		switch self {
		case .missingMetadata:
			return "The model file does not contain required metadata."
		case .invalidPath:
			return "Could not determine the storage path for the model."
		case .validationFailed:
			return "The model configuration is incomplete or invalid."
		}
	}
}

/// Blank provider used for the local file import path
private struct NoopProvider: ModelProvider {
	func result(_ error: ModelProviderError, id: UUID) { }
}

#if DEBUG
// MARK: - Preview

#Preview {
	ModelImportView(catalogProviders: [HuggingFaceCatalogProvider(), AppleCoreMLCatalogProvider()])
}
#endif
