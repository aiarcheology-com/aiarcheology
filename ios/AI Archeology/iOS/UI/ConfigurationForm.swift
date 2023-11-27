//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI

public enum AnnotationSymbol: String, CaseIterable, Identifiable {
	case point = "Point"
	case square = "Square"
	case circle = "Circle"

	public var id: String { self.rawValue }
}

struct ConfigurationDetailRow: View {
	@Environment(\.colorScheme) var colorScheme
	var label: String
	var value: String

	var body: some View {
		HStack {
			Text(label)
				.foregroundColor(colorScheme == .dark ? .white : .black)
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
	@Environment(\.colorScheme) var colorScheme
	var label: String
	@Binding var value: Double
	var range: ClosedRange<Double>

	var body: some View {
		VStack(alignment: .leading) {
			let formattedValue = String(format: "%.2f", value)
			ConfigurationDetailRow(label: label, value: formattedValue)
				.foregroundColor(colorScheme == .dark ? .white : .black)
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
	@State private var showDocumentPicker = false
	@State private var showErrorAlert = false
	@State private var errorMessage = ""

	var mergedObservable: [String] {[
		// Updated from the code: possibly should be not commented when a model file is re-loaded/updated.
		// configuration.file?.absoluteString ?? "",
		// configuration.model ?? "",
		// configuration.modelType ?? "",
		// configuration.author ?? "",
		// configuration.creationDate.description,
		// Updated from the user's input:
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.rawValue
	]}
	var body: some View {
		NavigationView {
			Form {
				if isCompleteConfiguration() {
					Section(header: Text("Model")) {
						ConfigurationDetailRow(label: "File", value: "\(configuration.file?.pathComponents.last ?? "")")
						ConfigurationDetailRow(label: "Model Name", value: "\(configuration.model ?? "")")
						ConfigurationDetailRow(label: "Model Type", value: " \(configuration.modelType ?? "")")
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
						showDocumentPicker: showDocumentPicker,
						configuration: configuration,
						usedFiles: usedFiles) { shouldShow in
							showDocumentPicker = shouldShow
						} onConfigurationChanged: { url, id in
							updateConfiguration(with: url, id: id)
						}
				}
			}
			.onReceive(deep.$deepStateError) { error in
				guard let error else { return }
				showDocumentPicker = false
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
				dismiss()
			}) {
				if isValidConfiguration {
					Text("Done").bold()
				} else {
					Text("Cancel").bold()
				}
			}
			.tint(isValidConfiguration ? .green : .blue))
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
			do {
				detector = try await Detector.loadModel(from: url) // We use here the instance of the Detector, but the code is common for all Create ML models.
			}
			catch {
				deep.deepStateError = error
			}
			guard let metadata = detector?.modelDescription.metadata else { return }
			let parser = MLModelMetadataParser(metadata: metadata)

			configuration.annotationColor = .yellow
			configuration.author = parser.value(for: .author) as? String
			configuration.creationDate_ = (parser.value(for: .date) as? String)?.toDate(.createMl)
			configuration.modelType = parser.task
			configuration.model = parser.value(for: .description) as? String
			configuration.phaseOutTime = 2
			configuration.selectedSymbol = .circle
			configuration.enabled = false
			configuration.file = try? url.relativePath(from: .documentDirectory)

			showDocumentPicker = false
			configuration.entityId = id
		}
	}
}


struct PressableButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundColor(.white)
			.padding(9)
			.background(configuration.isPressed ? Color.blue.opacity(0.5) : Color.blue)
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
