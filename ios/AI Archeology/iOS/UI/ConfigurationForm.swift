//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI

struct ConfigurationForm: View {
	@Binding var isPresented: Bool
	@State private var fileName: String = ""
	@State private var modelName: String = ""
	@State private var modelType: String = ""
	@State private var authorName: String = ""
	@State private var creationDate: Date = Date()
	@State private var annotationColor: Color = .black
	@State private var phaseOutTime: Double = 0
	@State private var selectedSymbol: AnnotationSymbol = .point

	enum AnnotationSymbol: String, CaseIterable, Identifiable {
		case point = "Point"
		case square = "Square"
		case circle = "Circle"

		var id: String { self.rawValue }
	}

	var body: some View {
		NavigationView {
			Form {
				Section(header: Text("Model Settings")) {
					TextField("File", text: $fileName)
					TextField("Name", text: $modelName)
					TextField("Type", text: $modelType)
				}

				Section(header: Text("Author")) {
					TextField("Author", text: $authorName)
					DatePicker("Created", selection: $creationDate, displayedComponents: .date)
				}

				Section(header: Text("Annotation")) {
					ColorPicker("Color", selection: $annotationColor)
					Slider(value: $phaseOutTime, in: 0...60)
					Picker("Symbol", selection: $selectedSymbol) {
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

