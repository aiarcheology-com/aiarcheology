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
							Spacer()
							Button(action: {
								showDocumentPicker = true
							}) {
								Image(systemName: "doc.badge.plus")
									.font(.largeTitle)
							}
							.sheet(isPresented: $showDocumentPicker) {
								DocumentPicker { url in
									configuration.fileName = url
									configuration.entityId = UUID() // just a test
									showDocumentPicker = false
								}
							}
							Spacer()
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
					Text("Done").bold().foregroundStyle(.green)
				} else {
					Text("Dismiss").bold()
				}
			}
			.buttonStyle(.bordered)
			.tint(isValidConfiguration ? .green : .blue))
		}
	}

	private func validateConfiguration() {
		do {
			try configuration.validateForInsert()
			isValidConfiguration = true
		} catch {
			isValidConfiguration = false
				// Handle the error, show an alert, etc.
		}
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
