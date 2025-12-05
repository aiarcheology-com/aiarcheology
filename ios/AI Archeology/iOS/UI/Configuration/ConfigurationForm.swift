//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI
import OSLog

struct ConfigurationDetailRow: View {
	var label: String
	var value: String
	
	var body: some View {
		HStack {
			Text(label)
				.foregroundColor(.primary)
				.fontWeight(.regular)
			
			Spacer()
			
			Text(value)
				.foregroundColor(.gray)
				.lineLimit(1)
				.truncationMode(.tail)
		}
	}
}

struct LabeledSlider: View {
	var label: String
	@Binding var value: Double
	var range: ClosedRange<Double>
	
	var body: some View {
		VStack(alignment: .leading) {
			let formattedValue = String(format: "%.2f", value)
			ConfigurationDetailRow(label: label, value: formattedValue)
				.foregroundColor(.primary)
				.fontWeight(.regular)
			
			Slider(value: $value, in: range)
				.testability(Testability.Slider.configurationFormFadeOutTime)
		}
	}
}

struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	@State private var showErrorAlert = false
	@State private var errorMessage = ""
	@State private var isLoading = false
	@State private var showImportAlert = false // new parent-owned alert state
	
	var mergedObservable: [String] {[
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.rawValue
	]}
	
	var body: some View {
		NavigationStack {
			configurationFormContent
		}
		.overlay {
			if isLoading {
				loadingOverlay
			}
		}
		.alert("Error", isPresented: $showErrorAlert) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(errorMessage)
		}
		.alert(isPresented: $showImportAlert) {
			var title = "Import Failed"
			var message = "The model could not be imported. Please try again with a valid Create ML model."
			if configuration.lifeCycle == .ready, let description = configuration.modelDescription, let author = configuration.author {
				title = "The model has been imported."
				message = "The model \(description) from \(author) has been successfully imported."
			}
			
			return Alert( title: Text(title), message: Text(message), dismissButton: .default(Text("OK")) {})
		}
	}
	
	private var loadingOverlay: some View {
		ZStack {
			Color.black.opacity(0.3)
				.ignoresSafeArea()
			
			ProgressView {
				Text("Fetching the model data ...")
			}
			.padding(24)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
		}
	}
	
	private var configurationFormContent: some View {
		Form {
			if isCompleteConfiguration() {
				modelSection
				authorSection
				annotationSection
			} else {
				newConfigurationSection
			}
		}
		.onChange(of: mergedObservable) {
			handleConfigurationChange()
		}
		.navigationBarTitle("Configuration", displayMode: .inline)
		.navigationBarItems(leading: navigationButton)
	}
	
	private var modelSection: some View {
		Section(header: Text("Model")) {
			ConfigurationDetailRow(label: "File", value: "\(configuration.file?.pathComponents.last ?? "")")
			ConfigurationDetailRow(label: "Decription", value: " \(configuration.modelDescription ?? "")")
			ConfigurationDetailRow( label: "Type", value: " \(configuration.modelType.rawValue)")
			ConfigurationDetailRow(label: "Version", value: " \(configuration.modelVersion ?? "")")
		}
	}
	
	private var authorSection: some View {
		Section(header: Text("Author")) {
			ConfigurationDetailRow(label:"Author", value: "\(configuration.author ?? "")")
			ConfigurationDetailRow(label:"Created", value: "\(configuration.creationDate)")
		}
	}
	
	private var annotationSection: some View {
		Section(header: Text("Annotation")) {
			ColorPicker("Color", selection: $configuration.annotationColor)
				.testability(Testability.ColorPicker.configurationFormAnnotationColor)
			LabeledSlider(label: "Fade Out Time", value: $configuration.phaseOutTime, range: 0.2...10)
			Picker("Symbol", selection: $configuration.selectedSymbol) {
				ForEach(AnnotationSymbol.allCases) { symbol in
					Text(symbol.rawValue).tag(symbol)
				}
			}
			.testability(Testability.Picker.configurationFormSymbol)
		}
	}
	
	private var newConfigurationSection: some View {
		let usedFiles = deep.allConfigurations().compactMap { $0.file }
		return NewConfigurationView(
			usedFiles: usedFiles,
			onConfigurationChanged: { url, id, provider in
				try await updateConfiguration(with: url, id: id, provider: provider)
			},
			onImportFinished: {
				showImportAlert = true
			},
			onLoadingStateChanged: { loading in
				isLoading = loading
			},
			onError: { error in
				errorMessage = error.localizedDescription
				showErrorAlert = true
			}
		)
	}
	
	private var navigationButton: some View {
		Button(action: handleNavigationButtonTap) {
			if configuration.lifeCycle == .ready {
				Text("Done").bold()
			} else {
				Text("Cancel").bold()
			}
		}
		.testability(configuration.lifeCycle == .ready ? Testability.Button.configurationFormDone : Testability.Button.configurationFormCancel)
		.tint(configuration.lifeCycle == .ready ? .green : .blue)
	}
	
	private func handleNavigationButtonTap() {
		if configuration.lifeCycle == .ready {
			deep.saveConfigurations()
		} else {
			if configuration.isPersisted {
				deep.deleteConfiguration(configuration)
			}
		}
		dismiss()
	}
	
	private func handleConfigurationChange() {
		validateConfiguration()
		if configuration.lifeCycle == .ready {
			deep.saveConfigurations()
		}
	}
	
	private func isCompleteConfiguration() -> Bool {
		configuration.lifeCycle == .ready
	}
	
	private func validateConfiguration() {
		do {
			try configuration.validateForInsert()
			configuration.lifeCycle = .ready
		} catch {
			configuration.lifeCycle = .draft
		}
	}
	
	@MainActor
	private func updateConfiguration(with url: URL, id: UUID, provider: ModelProvider) async throws {
		// Update the DeepConfiguration
		assert(url.absoluteString.isEmpty.not, "URL of the file should not be empty.")
		
		// Create detector to fetch the info. This call does not register the detector for use.
		// The detectors are automatically registered in the DeepState class
		// after a specific DeepConfiguration has been saved in the context.
		// Note: Loading state and errors are managed by the caller via callbacks,
		// which are set BEFORE this async function starts, giving SwiftUI a render cycle.
		let detector = try await Detector.loadModel(from: url)
		
		guard let metadata = detector?.modelDescription.metadata else { return }
		let parser = MLModelMetadataParser(metadata: metadata)
		
		configuration.entityId = id
		configuration.annotationColor = .yellow
		let description = parser.value(for: .description) as? String
		let modelDescrition = description.isNotBlank ? description : url.lastPathComponent.fileName
		configuration.modelDescription = modelDescrition
		configuration.modelVersion = parser.value(for: .versionString) as? String
		configuration.author = parser.value(for: .author) as? String
		configuration.creationDate_ = (parser.value(for: .date) as? String)?.toDate(.createMl)
		configuration.modelType = parser.task
		configuration.phaseOutTime = 2
		configuration.selectedSymbol = .circle
		guard let relativePath = try? url.relativePath(from: DeepConfiguration.rootDirectory) else {
			Logger.configuration.logError("Failed to compute relative path for model file")
			return
		}
		configuration.file_ = relativePath
		configuration.enabled = false
		configuration.transition(to: .draft)
		validateConfiguration()
		// This line saves the new configurations.
		// DeepState creates and registeres the detectors and the SideMenu is updated.
		// Any time a deep configuration is created/deleted, a new detector is created/deleted.
		let importResult: ModelProviderError
		if configuration.lifeCycle == .ready {
			deep.saveConfigurations()
			importResult = .importSucceeded
		} else {
			Logger.configuration.logWarning("Configuration validation failed - incomplete data")
			importResult = .importFailed
		}
		
		let id = configuration.entityId
		provider.result(importResult, id: id)
	}
}


struct PressableButtonStyle: ButtonStyle {
	var color: Color = .blue
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundColor(.white)
			.padding(9)
			.background(configuration.isPressed ? color.opacity(0.5) : color)
			.cornerRadius(10)
			.shadow(radius: configuration.isPressed ? 5 : 10)
			.scaleEffect(configuration.isPressed ? 0.9 : 1.0)
			.animation(.spring(response: 0.3, dampingFraction: 0.5, blendDuration: 0), value: configuration.isPressed)
	}
}

import CoreML

enum ExtendedMLModelMetadataKey: Hashable {
	case standard(MLModelMetadataKey)
	case custom(String)
	
	var key: String {
		switch self {
		case .standard(let key):
			return key.rawValue
		case .custom(let key):
			return key
		}
	}
	
	// Standard keys
	static let description = ExtendedMLModelMetadataKey.standard(.description)
	static let versionString = ExtendedMLModelMetadataKey.standard(.versionString)
	static let author = ExtendedMLModelMetadataKey.standard(.author)
	static let license = ExtendedMLModelMetadataKey.standard(.license)
	static let creatorDefined = ExtendedMLModelMetadataKey.standard(.creatorDefinedKey)
	
	// User defined keys from Ultralytics
	static let date = ExtendedMLModelMetadataKey.custom("date")
	static let confidenceThreshold = ExtendedMLModelMetadataKey.custom("Confidence threshold")
	static let iouThreshold = ExtendedMLModelMetadataKey.custom("IoU threshold")
	static let task = ExtendedMLModelMetadataKey.custom("task")
	static let imgsz = ExtendedMLModelMetadataKey.custom("imgsz")
	static let batch = ExtendedMLModelMetadataKey.custom("batch")
	static let names = ExtendedMLModelMetadataKey.custom("names")
	
	// User defined keys from Create ML
	static let createMLVersion = ExtendedMLModelMetadataKey.custom("com.apple.createml.version")
	static let createMLAppTag = ExtendedMLModelMetadataKey.custom("com.apple.createml.app.tag")
	static let iterations = ExtendedMLModelMetadataKey.custom("iterations")
	static let createMLAppVersion = ExtendedMLModelMetadataKey.custom("com.apple.createml.app.version")
	static let coreMLModelPreviewType = ExtendedMLModelMetadataKey.custom("com.apple.coreml.model.preview.type")
}

struct MLModelMetadataParser {
	private let metadata: [String: Any]
	private var creatorDefinedMetadata: [String: Any]?
	
	init(metadata rawMetadata: [MLModelMetadataKey: Any]) {
		self.metadata = rawMetadata.reduce(into: [String: Any]()) { result, pair in
			result[pair.key.rawValue] = pair.value
		}
		self.creatorDefinedMetadata = self.metadata[MLModelMetadataKey.creatorDefinedKey.rawValue] as? [String: Any]
	}
	
	func value(for key: ExtendedMLModelMetadataKey) -> Any? {
		switch key {
		case .standard(let standardKey):
			return metadata[standardKey.rawValue]
		case .custom(let customKey):
			return creatorDefinedMetadata?[customKey]
		}
	}
	
	var task: DeepDriverType {
		let task = self.value(for: .task) as? String ?? self.value(for: .coreMLModelPreviewType) as? String
		switch(task) {
		case "detect", "objectDetector": return DeepDriverType(rawValue: task ?? "detect") ?? .detector
		case "classify", "objectClassificator": return DeepDriverType(rawValue: task ?? "classify") ?? .classificator
		default: return .invalid
		}
	}
}
