//
//  ModelImportView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

/// View for importing ML models either from local files or remote URLs.
///
/// Provides educational content about supported model types and
/// conversion instructions for ONNX models.
struct ModelImportView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc
	@EnvironmentObject private var deep: DeepState
	@EnvironmentObject private var downloader: Downloader
	
	@StateObject private var acquisitionCoordinator = ModelAcquisitionCoordinator(
		allowedTypes: [
			UTType("com.apple.coreml.mlmodel"),
			UTType("com.apple.coreml.mlpackage"),
			UTType(filenameExtension: "mlmodel"),
			UTType(filenameExtension: "mlpackage"),
			UTType(filenameExtension: "mlmodelc")
		].compactMap { $0 }
	)
	
	/// Holds remote import data until the sheet finishes dismissing
	@State private var pendingRemoteImport: (url: URL, id: UUID, downloadUrl: URL, provider: ModelProvider)?
	
	/// Loading state during model validation
	@State private var isLoading = false
	
	/// Error to display in alert
	@State private var errorMessage: String?
	@State private var showErrorAlert = false
	
	/// Success state with imported model info
	@State private var importedModelInfo: ImportedModelInfo?
	
	private static let pythonCode = """
	import coremltools as ct
	
	# Load the ONNX model
	onnx_model = ct.onnx.load_model("path_to_your_model.onnx")
	
	# Convert the model
	coreml_model = ct.convert(onnx_model, source='onnx')
	
	# Save the converted model
	coreml_model.save("your_model.mlmodel")
	"""
	
	var body: some View {
		NavigationStack {
			contentList
				.navigationTitle("Import Model")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar { toolbarContent }
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
		.alert("Error", isPresented: $showErrorAlert) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage ?? "An unknown error occurred.")
		}
		.alert("Model Imported", isPresented: .init(
			get: { importedModelInfo != nil },
			set: { if !$0 { importedModelInfo = nil } }
		)) {
			Button("OK") {
				importedModelInfo = nil
				dismiss()
			}
		} message: {
			if let info = importedModelInfo {
				Text("The model \(info.description) from \(info.author) has been successfully imported.")
			} else {
				Text("The model has been imported successfully.")
			}
		}
		.presentationDetents([.large])
	}
	
	// MARK: - Content
	
	private var contentList: some View {
		List {
			importButtonsSection
			instructionsSection
			documentationSection
			conversionSection
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
						Text("Import from Files")
							.foregroundStyle(Color(.label))
						Text("Select a .mlmodel or .mlpackage file")
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
						Text("Download from URL")
							.foregroundStyle(Color(.label))
						Text("Download a model from the internet")
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
		}
	}
	
	// MARK: - Instructions Section
	
	private var instructionsSection: some View {
		Section {
			Text("Choose a Create ML model (.mlmodel or .mlpackage) that supports object detection. Other model types are not supported in this version.")
				.font(.subheadline)
				.foregroundStyle(Color(.secondaryLabel))
		} header: {
			Text("Supported Models")
		}
	}
	
	// MARK: - Documentation Section
	
	private var documentationSection: some View {
		Section {
			Link(destination: URL(string: "https://developer.apple.com/documentation/createml")!) {
				Label("Apple Create ML Documentation", systemImage: "book")
			}
			.testability(Testability.Link.newConfigurationAppleDocumentation)
			
			Link(destination: URL(string: "https://developer.apple.com/videos/play/wwdc2020/10153/")!) {
				Label("WWDC: Core ML Converters", systemImage: "play.rectangle")
			}
			.testability(Testability.Link.newConfigurationCoreMLConverters)
		} header: {
			Text("Learn More")
		}
	}
	
	// MARK: - Conversion Section
	
	private var conversionSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 12) {
				Text("Use this Python code to convert ONNX models:")
					.font(.subheadline)
					.foregroundStyle(Color(.secondaryLabel))
				
				Text(Self.pythonCode)
					.font(.system(.caption, design: .monospaced))
					.padding(12)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(.tertiarySystemBackground))
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.copiedToClipboard(copiedText: Self.pythonCode, preview: String(Self.pythonCode.prefix(80)))
			}
		} header: {
			Text("ONNX Conversion")
		}
	}
	
	// MARK: - Toolbar
	
	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .topBarTrailing) {
			Button("Dismiss") {
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
			
			ProgressView {
				Text("Validating model...")
			}
			.padding(24)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
		}
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
		isLoading = true
		
		Task { @MainActor in
			do {
				let info = try await importConfiguration(from: request.url, downloadUrl: request.downloadUrl, id: request.configurationId, provider: request.provider)
				importedModelInfo = info
			} catch {
				errorMessage = error.localizedDescription
				showErrorAlert = true
			}
			isLoading = false
			acquisitionCoordinator.markImportHandled()
		}
	}
	
	/// Import and validate a model configuration
	/// - Parameters:
	///   - sourceURL: Local file URL of the model
	///   - downloadUrl: Original download URL (nil for local file imports, non-nil for remote downloads)
	///   - id: Configuration identifier
	///   - provider: Model provider for result callbacks
	/// - Returns: Info about the imported model for display in success alert
	@discardableResult
	private func importConfiguration(from sourceURL: URL, downloadUrl: URL?, id: UUID, provider: ModelProvider) async throws -> ImportedModelInfo {
		// Create a new configuration entity
		let configuration = DeepConfiguration.create(in: moc)
		
		// Copy file to Documents if needed (file picker returns source location)
		let modelURL = try FileManager.storeModelInDocuments(from: sourceURL, configurationId: id)
		
		// Load and validate the model
		let detector = try await Detector.loadModel(from: modelURL)
		guard let metadata = detector?.modelDescription.metadata else {
			moc.delete(configuration)
			throw ImportError.missingMetadata
		}
		
		let parser = MLModelMetadataParser(metadata: metadata)
		
		// Populate configuration
		configuration.entityId = id
		configuration.annotationColor = .yellow
		let description = parser.value(for: .description) as? String
		configuration.modelDescription = description.isNotBlank ? description : modelURL.lastPathComponent.fileName
		configuration.modelVersion = parser.modelVersion
		configuration.author = parser.value(for: .author) as? String
		configuration.creationDate_ = (parser.value(for: .date) as? String)?.toDate(.createMl)
		configuration.modelType = parser.task
		configuration.phaseOutTime = 2
		configuration.selectedSymbol = .circle
		
		guard let relativePath = try? modelURL.relativePath(from: DeepConfiguration.rootDirectory) else {
			moc.delete(configuration)
			LoggingPolicy.error("Failed to compute relative path for model file", logger: .configuration)
			throw ImportError.invalidPath
		}
		
		configuration.file_ = relativePath
		configuration.downloadURL = downloadUrl
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
			
			return ImportedModelInfo(
				description: configuration.modelDescription ?? "Unknown",
				author: configuration.author ?? "Unknown"
			)
		} else {
			moc.delete(configuration)
			provider.result(.importFailed, id: id)
			throw ImportError.validationFailed
		}
	}
}

// MARK: - Imported Model Info

/// Information about an imported model for display in success alert
private struct ImportedModelInfo {
	let description: String
	let author: String
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

// MARK: - Preview

#Preview {
	ModelImportView()
}
