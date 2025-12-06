//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI
import CoreML

// MARK: - Supporting Views

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

// MARK: - Configuration Form

/// Form for viewing and editing an existing ML model configuration.
struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	
	private var mergedObservable: [String] {[
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.rawValue
	]}
	
	var body: some View {
		NavigationStack {
			Form {
				modelSection
				authorSection
				annotationSection
			}
			.onChange(of: mergedObservable) {
				deep.saveConfigurations()
			}
			.navigationBarTitle("Configuration", displayMode: .inline)
			.navigationBarItems(trailing: doneButton)
		}
	}
	
	// MARK: - Sections
	
	private var modelSection: some View {
		Section(header: Text("Model")) {
			ConfigurationDetailRow(label: "File", value: "\(configuration.file?.pathComponents.last ?? "")")
			ConfigurationDetailRow(label: "Decription", value: " \(configuration.modelDescription ?? "")")
			ConfigurationDetailRow(label: "Type", value: " \(configuration.modelType.rawValue)")
			ConfigurationDetailRow(label: "Version", value: " \(configuration.modelVersion ?? "")")
		}
	}
	
	private var authorSection: some View {
		Section(header: Text("Author")) {
			ConfigurationDetailRow(label: "Author", value: "\(configuration.author ?? "")")
			ConfigurationDetailRow(label: "Created", value: "\(configuration.creationDate)")
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
	
	// MARK: - Navigation
	
	private var doneButton: some View {
		Button(action: {
			deep.saveConfigurations()
			dismiss()
		}) {
			Text("Done").bold()
		}
		.testability(Testability.Button.configurationFormDone)
		.tint(.green)
	}
}

// MARK: - Button Style

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

// MARK: - ML Model Metadata

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
