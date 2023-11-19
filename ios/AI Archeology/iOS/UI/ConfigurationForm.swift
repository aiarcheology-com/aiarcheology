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
					TextField("File", text: $configuration.fileName)
					TextField("Name", text: $configuration.modelName)
					Text(configuration.modelType.name())
				}

				Section(header: Text("Author")) {
					TextField("Author", text: $configuration.authorName)
					DatePicker("Created", selection: $configuration.creationDate, displayedComponents: .date)
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
			.navigationBarItems(trailing: Button("Dismiss") {
				isPresented = false
			})
		}
	}
}

