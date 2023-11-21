//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI

enum AnnotationSymbol: String, CaseIterable, Identifiable {
	case point = "Point"
	case square = "Square"
	case circle = "Circle"

	var id: String { self.rawValue }
}

struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	@State private var isValidConfiguration = false
	@State private var showDocumentPicker = false
	var mergedObservable: [String] {[
		configuration.fileName?.absoluteString ?? "",
		configuration.modelName ?? "",
		configuration.modelType ?? "",
		configuration.authorName ?? "",
		configuration.creationDate.description,
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.description
	]}
	var body: some View {
		NavigationView {
			Form {
				// We are editing the existing configuration:
				if configuration.entityId.isNotNil {
					Section(header: Text("Model Settings")) {
						Text("File: \(configuration.fileName?.absoluteString ?? "")")
						Text("Model Name: \(configuration.modelName ?? "")")
						Text("Model Type: \(configuration.modelType ?? "")")
					}

					Section(header: Text("Author")) {
						Text("Author: \(configuration.authorName ?? "")" )
						Text("Created: \(configuration.creationDate)")
					}

					Section(header: Text("Annotation")) {
						ColorPicker("Color", selection: $configuration.annotationColor)
						Slider(value: $configuration.phaseOutTime, in: 0...60)
						Picker("Symbol", selection: $configuration.selectedSymbol) {
							ForEach(AnnotationSymbol.allCases) { symbol in
								Text(symbol.rawValue).tag(symbol)
							}
						}
					}
				} else {
					// We are creating a new configuration:
					VStack {
						Spacer()
						HStack {
							VStack {
								Spacer()
								HStack {
									Section {
										Button(action: {
											showDocumentPicker = true
										}) {
											Image(systemName: "doc.badge.plus")
												.font(.largeTitle)
										}
									} footer: {
										Spacer()
										Text("Select a Create ML model supporting the object detection. Other models are not supported in this version.")
									}
								}
								Section {
									Spacer()
									Button (action: {
										showDocumentPicker = true
									}) {
										Text("Open").bold()
									}
									.buttonStyle(PressableButtonStyle())
									Spacer()
								}
								Spacer()
							}
						}
						.sheet(isPresented: $showDocumentPicker) {
							DocumentPicker { url in
								Task {
									let detector = Detector()
									await detector.loadModel(from: url)
									let metadata = await detector.metadata()
									configuration.fileName = url
									configuration.entityId = UUID()
//									let author = metadata[.author] as? String
//									let license = metadata[.license] as? String
//									let description = metadata[.description] as? String
//									let versionString = metadata[.versionString] as? String

									showDocumentPicker = false
								}
							}
						}
						Spacer()
					}
				}
			}
			.onChange(of: mergedObservable) { _ in
				validateConfiguration()
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

	private func validateConfiguration() {
		do {
			try configuration.validateForInsert()
			isValidConfiguration = true
		} catch {
			isValidConfiguration = false
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

struct DocumentPicker: UIViewControllerRepresentable {
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
			parent.onPick(url)
		}
	}
}
