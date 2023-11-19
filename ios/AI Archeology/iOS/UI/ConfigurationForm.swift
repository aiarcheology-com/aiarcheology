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
					Text(configuration.fileName.absoluteString)
					TextField("Name", text: $configuration.modelName)
					Text(configuration.modelType.name())
				}

				Section(header: Text("Author")) {
					Text(configuration.authorName)
					let created = configuration.creationDate.formatted(.dateTime.year().month().day().hour().minute())
					Text("Created: \(created)")
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
				Text("Dismiss").bold()
			})
		}
	}
}

