//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI

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
		}
	}
}

struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	@State private var isValidConfiguration = false
	@State private var showErrorAlert = false
	@State private var errorMessage = ""
	@State private var isLoading = false

	var mergedObservable: [String] {[
		// Updated from the user's input:
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.rawValue
	]}
	var body: some View {
		NavigationView {
			if isLoading {
				ProgressView {
					Text("Fetching the model data ...")
				}
				.navigationTitle("Configuration")
				.navigationBarTitleDisplayMode(.inline)
			} else {
				Form {
					if isCompleteConfiguration() {
						Section(header: Text("Model")) {
							ConfigurationDetailRow(label: "File", value: "\(configuration.file?.pathComponents.last ?? "")")
							ConfigurationDetailRow(label: "Decription", value: " \(configuration.modelDescription ?? "")")
							ConfigurationDetailRow(label: "Type", value: " \(configuration.modelType ?? "")")
							ConfigurationDetailRow(label: "Version", value: " \(configuration.modelVersion ?? "")")
						}

						Section(header: Text("Author")) {
							ConfigurationDetailRow(label:"Author", value: "\(configuration.author ?? "")")
							ConfigurationDetailRow(label:"Created", value: "\(configuration.creationDate)")
						}

						Section(header: Text("Annotation")) {
							ColorPicker("Color", selection: $configuration.annotationColor)
							LabeledSlider(label: "Fade Out Time", value: $configuration.phaseOutTime, range: 0.2...10)
								// TODO: define constants for the limits
							Picker("Symbol", selection: $configuration.selectedSymbol) {
								ForEach(AnnotationSymbol.allCases) { symbol in
									Text(symbol.rawValue).tag(symbol)
								}
							}
						}
					} else /* isNewConfiguration */ {
						let usedFiles = deep.allConfigurations().compactMap { $0.file }

						NewConfigurationView(
							usedFiles: usedFiles) { url, id in
								updateConfiguration(with: url, id: id)
						}
					}
				}
				.onReceive(deep.$deepStateError) { error in
					guard let error else { return }
					errorMessage = error.localizedDescription
					showErrorAlert = true
				}
				.alert(isPresented: $showErrorAlert) {
					Alert(title: Text("Error"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
				}
				.onChange(of: mergedObservable) { _ in
					validateConfiguration()
					if isValidConfiguration {
							// This line saves the new configurations.
							// DeepState creates and registeres the detectors and the SideMenu is updated.
							// Any time a deep configuration is created/deleted, a new detector is created/deleted.
						deep.saveConfigurations()
					}
				}
				.navigationBarTitle("Configuration", displayMode: .inline)
				.navigationBarItems(trailing: Button(action: {
					if isValidConfiguration {
						deep.saveConfigurations()
					} else {
						let editingConfiguration = configuration.entityId?.uuidString.isEmpty == false
						guard editingConfiguration.not else {
							dismiss()
							return
						}
						deep.deleteConfiguration(configuration)
					}
					dismiss()
				}) {
					if isValidConfiguration {
						Text("Done").bold()
					} else {
						Text("Cancel").bold()
					}
				}
					.tint(isValidConfiguration ? .green : .blue)
				)
			}
		}
	}

	private func isCompleteConfiguration() -> Bool {
		configuration.entityId.isNotNil && configuration.entityId?.uuidString.isEmpty == false
	}

	private func validateConfiguration() {
		do {
			try configuration.validateForInsert()
			isValidConfiguration = true
		} catch {
			isValidConfiguration = false
		}
	}

	private func updateConfiguration(with url: URL, id: UUID) {
		Task {
			// Update the DeepConfiguration
			assert(url.absoluteString.isEmpty.not, "URL of the file should not be empty.")

			// Create detector to fetch the info. This call does not register the detector for use.
			// The detectors are automatically registered in the DeepState class
			// after a specific DeepConfiguration has been saved in the context.
			var detector: MLModel?
			isLoading = true // show the spinner

			Task {
				do {
					// We use here the instance of the Detector, but the code is common for all Create ML models.
					detector = try await Detector.loadModel(from: url)
				}
				catch {
					deep.deepStateError = error
				}

				isLoading = false

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
				guard let file = try? url.relativePath(from: DeepConfiguration.rootDirectory) else {
					assert(false, "Model file is required.")
					return
				}
				configuration.file_ = file
				configuration.enabled = false
				configuration.readyToValidate = true
				validateConfiguration()
					// This line saves the new configurations.
					// DeepState creates and registeres the detectors and the SideMenu is updated.
					// Any time a deep configuration is created/deleted, a new detector is created/deleted.
				if isValidConfiguration {
					deep.saveConfigurations()
				} else {
					assert(false, "Not all data are complete in the new deep configuration.")
				}
			}
		}
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

	var task: String {
		let task = self.value(for: .task) as? String ?? self.value(for: .coreMLModelPreviewType) as? String
		switch(task) {
			case "detect": return "detect"
			case "objectDetector": return "detect"
			default: return "error: missing type"
		}
	}
}
