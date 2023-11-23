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
	var label: String
	var value: String

	var body: some View {
		HStack {
			Text(label)
				.foregroundColor(.black)
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
			Text("\(label): \(value, specifier: "%.2f")")
				.foregroundColor(.black)
				.fontWeight(.regular)

			Slider(value: $value, in: range)
		}
	}
}

struct NewConfigurationView: View {
	let showDocumentPicker: Bool
	let configuration: DeepConfiguration
	let onDocumentPickerToggle: (Bool) -> Void // Using callbacks as the compiler is not able to compile
	let onConfigurationChanged: (URL) -> Void  // these lines with normal @Binding's.

	var body: some View {
		VStack {
			Spacer()
			Section {
				Button(action: {
					onDocumentPickerToggle(true)
				}) {
					Image(systemName: "doc.badge.plus")
						.font(Font(.init(.label, size: 60.0)))
				}
				.buttonStyle(PressableButtonStyle())
			} header: {
				Text("Select a Create ML model supporting the object detection. Other models are not supported in this version.")
			}
			Spacer()
		}
		.sheet(isPresented: .constant(showDocumentPicker)) {
			DocumentPicker { url in
				onConfigurationChanged(url)
			}
		}
	}
}

struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	@State private var isValidConfiguration = false
	@State private var showDocumentPicker = false
	var mergedObservable: [String] {[
		configuration.file?.absoluteString ?? "",
		configuration.model ?? "",
		configuration.modelType ?? "",
		configuration.author ?? "",
		configuration.creationDate.description,
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
						ConfigurationDetailRow(label:"Author", value: "\(configuration.author ?? "")" )
						ConfigurationDetailRow(label:"Created", value: "\(configuration.creationDate)")
					}

					Section(header: Text("Annotation")) {
						ColorPicker("Color", selection: $configuration.annotationColor)
						LabeledSlider(label: "Phase Out Time", value: $configuration.phaseOutTime, range: 0...60)
						Picker("Symbol", selection: $configuration.selectedSymbol) {
							ForEach(AnnotationSymbol.allCases) { symbol in
								Text(symbol.rawValue).tag(symbol)
							}
						}
					}
				} else /* isNewConfiguration */ {
					NewConfigurationView(
						showDocumentPicker: showDocumentPicker,
						configuration: configuration,
						onDocumentPickerToggle: { shouldShow in
							showDocumentPicker = shouldShow
						},
						onConfigurationChanged: { url in
							updateConfiguration(with: url)
						}
					)
				}
			}
			.onChange(of: mergedObservable) { _ in
				validateConfiguration()
				if isValidConfiguration {
					// This line saves the new configurations. DeepState creates and registeres the detectors.
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

	private func updateConfiguration(with url: URL) {
		Task {
			// Update the DeepConfiguration
			assert(url.absoluteString.isEmpty.not, "URL of the file should not be empty.")
			configuration.enabled = false
			configuration.entityId = UUID()
			configuration.file = url

			// Create detector to fetch the info. This call does not register the detector for use.
			// The detectors are automatically registered in the DeepState class
			// after a specific DeepConfiguration has been saved in the context.
			let detector = await Detector.loadModel(from: url) // We use here the instance of the Detector, but the code is common for all Create ML models.

			guard let metadata = detector?.modelDescription.metadata else { return }
			let parser = MLModelMetadataParser(metadata: metadata)

			configuration.annotationColor = .yellow
			configuration.author = parser.value(for: .author) as? String
			configuration.creationDate_ = (parser.value(for: .date) as? String)?.toDate(.createMl)
			configuration.modelType = parser.value(for: .task) as? String
			configuration.model = parser.value(for: .description) as? String
			configuration.phaseOutTime = 2
			configuration.selectedSymbol = .circle

			showDocumentPicker = false
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


import SwiftUI
import UIKit
// TODO: Remove the file with the configuration
struct DocumentPicker: UIViewControllerRepresentable {
	@State private var documentURL: URL?

	var onPick: (URL) -> Void

	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
		picker.allowsMultipleSelection = false
		picker.delegate = context.coordinator
		return picker
	}

	func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
			// unused
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	class Coordinator: NSObject, UIDocumentPickerDelegate {
		var parent: DocumentPicker

		init(_ parent: DocumentPicker) {
			self.parent = parent
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			guard let url = urls.first else { return }

			let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			let fileName = url.lastPathComponent
			let destinationURL = documentsDirectory.appendingPathComponent(fileName)

			try? FileManager.default.moveItem(at: url, to: destinationURL)
			parent.documentURL = destinationURL

			parent.onPick(destinationURL)
		}
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

	// User defined keys
	static let date = ExtendedMLModelMetadataKey.custom("date")
	static let confidenceThreshold = ExtendedMLModelMetadataKey.custom("Confidence threshold")
	static let iouThreshold = ExtendedMLModelMetadataKey.custom("IoU threshold")
	static let task = ExtendedMLModelMetadataKey.custom("task")
	static let imgsz = ExtendedMLModelMetadataKey.custom("imgsz")
	static let batch = ExtendedMLModelMetadataKey.custom("batch")
	static let names = ExtendedMLModelMetadataKey.custom("names")
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
}
