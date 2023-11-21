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
	@Binding var isPresented: Bool
	@EnvironmentObject var configuration: DeepConfiguration
	var body: some View {
		NavigationView {
			Form {
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
			}
			.navigationBarTitle("Configuration", displayMode: .inline)
			.navigationBarItems(leading: 	Button(action: {

			}) {
				Image(systemName: "plus")
			})
			.navigationBarItems(trailing: Button(action: {
				isPresented = false
			}) {
				Text("Done").bold()
			})
		}
	}
}

