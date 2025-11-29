//
//  NewConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import OSLog

private enum ImportRoute: Hashable {
	case downloader
	case importer
}

struct NewConfigurationView: View {
	@EnvironmentObject var deep: DeepState
	@Environment(\.dismiss) private var dismiss
	
	@StateObject private var acquisitionCoordinator = ModelAcquisitionCoordinator(
		allowedTypes: [
			// Core ML model types
			UTType("com.apple.coreml.mlmodel"),
			UTType("com.apple.coreml.mlpackage"),
			// Fallback to extension-based types if identifiers don't work
			UTType(filenameExtension: "mlmodel"),
			UTType(filenameExtension: "mlpackage"),
			UTType(filenameExtension: "mlmodelc")
		].compactMap { $0 }
	)
	
	let usedFiles: [URL]
	let onConfigurationChanged: (URL, UUID, ModelProvider) async throws -> Void
	let onImportFinished: @MainActor () -> Void
	let onLoadingStateChanged: @MainActor (Bool) -> Void
	let onError: @MainActor (Error) -> Void
	
	private static let pythonCode = """
	import coremltools as ct
	
	# Load the ONNX model
	onnx_model = ct.onnx.load_model("path_to_your_model.onnx")
	
	# Convert the model
	coreml_model = ct.convert(onnx_model, source='onnx')
	
	# Save the converted model
	coreml_model.save("your_model.mlmodel")
	"""
	
	// Blank provider used for the fileImporter path
	private struct NoopProvider: ModelProvider {
		func result(_ error: ModelProviderError, id: UUID) { }
	}
	
	var body: some View {
		NavigationStack {
			List {
				Section {
					Text("Choose a Create ML model (.mlmodel or .mlpackage) that supports object detection. Other model types are not supported in this version.")
						.frame(maxWidth: .infinity, alignment: .leading)
						.multilineTextAlignment(.leading)
				} header: {
					EmptyView()
				} footer: {
					SourceButtons(
						onPickDocument: { acquisitionCoordinator.beginLocalImport() },
						onPickURL:      { acquisitionCoordinator.beginRemoteImport() }
					)
					.padding(12)
				}
				
				Section {
					Link("Apple Documentation: Create ML", destination: URL(string: "https://developer.apple.com/documentation/createml")!)
						.frame(maxWidth: .infinity, alignment: .leading)
				} header: {
					Text("Learn more about creating a detector in Create ML:")
						.font(.headline)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textCase(nil)
				}
				
				Section {
					Link("Get models on device using Core ML Converters", destination: URL(string: "https://developer.apple.com/videos/play/wwdc2020/10153/")!)
						.frame(maxWidth: .infinity, alignment: .leading)
					Text(Self.pythonCode)
						.font(.system(.body, design: .monospaced))
						.frame(maxWidth: .infinity, alignment: .leading)
						.multilineTextAlignment(.leading)
						.padding(.vertical)
						.copiedToClipboard(copiedText: Self.pythonCode, preview: String(Self.pythonCode.prefix(80)))
				} header: {
					Text("Python Code to Convert ONNX to Create ML:")
						.font(.headline)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textCase(nil)
				}
			}
			.navigationTitle("New Configuration")
			.navigationBarTitleDisplayMode(.inline)
			.onReceive(deep.$deepStateError) { error in
				if let error = error {
					Logger.ui.logError("DeepState error in NewConfigurationView: \\ (error.localizedDescription)")
					onError(error)
				}
			}
			// Present downloader as a sheet for now; can be changed to navigation if desired.
			.sheet(isPresented: $acquisitionCoordinator.isShowingDownloader) {
				NavigationStack {
					DownloaderView(
						onImport: ImportHandler { url, id, provider in
							// Dismiss the sheet first so the loading overlay is visible
							acquisitionCoordinator.isShowingDownloader = false
							// Small delay to let the sheet dismiss animation complete
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
								acquisitionCoordinator.completeRemoteImport(url: url, configurationId: id, provider: provider)
							}
						}
					)
				}
			}
			// Host the standard SwiftUI fileImporter using coordinator state.
			.fileImporter(
				isPresented: $acquisitionCoordinator.isShowingFileImporter,
				allowedContentTypes: acquisitionCoordinator.allowedTypes,
				allowsMultipleSelection: false
			) { result in
				switch result {
				case .success(let urls):
					if let url = urls.first {
						acquisitionCoordinator.completeLocalImport(url: url, provider: NoopProvider())
					}
				case .failure:
					break
				}
			}
			// React to a resolved import once, performing the async configuration change.
			.onChange(of: acquisitionCoordinator.pendingImport) { request in
				guard let request else { return }
				onLoadingStateChanged(true)
				Task { @MainActor in
					do {
						try await onConfigurationChanged(request.url, request.configurationId, request.provider)
						onImportFinished()
					} catch {
						onError(error)
					}
					onLoadingStateChanged(false)
					acquisitionCoordinator.markImportHandled()
				}
			}
		}
	}
}

fileprivate struct SourceButtons: View {
	var onPickDocument: () -> Void
	var onPickURL: () -> Void
	
	var body: some View {
		HStack {
			Spacer()
			PlusIconButton(systemName: "doc") { onPickDocument() }
			Spacer()
			PlusIconButton(systemName: "globe") { onPickURL() }
			Spacer()
		}
		.padding(12)
	}
}

fileprivate struct PlusIconButton: View {
	var systemName: String
	var action: () -> Void
	
	var body: some View {
		Button(action: action) {
			ZStack(alignment: .bottomLeading) {
				Image(systemName: systemName)
					.resizable()
					.frame(width: 70, height: 70)
				ZStack {
					Circle()
						.frame(width: 37, height: 37)
						.foregroundColor(.blue)
					Image(systemName: "plus.circle.fill")
						.resizable()
						.frame(width: 30, height: 30)
				}
				.alignmentGuide(.bottom) { d in d[.bottom] }
				.alignmentGuide(.leading) { d in d[.leading] }
			}
		}
		.buttonStyle(PressableButtonStyle())
	}
}
