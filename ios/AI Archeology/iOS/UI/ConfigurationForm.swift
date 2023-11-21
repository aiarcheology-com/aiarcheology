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
	var body: some View {
		NavigationView {
			Form {
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
					Button(action: {
						// load a file
					}) {
						Image(systemName: "plus")
					}
				}
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

