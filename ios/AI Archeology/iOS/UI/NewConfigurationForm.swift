//
//  NewConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI

import Foundation
import SwiftUI

struct NewConfigurationView: View {
	let showDocumentPicker: Bool
	let configuration: DeepConfiguration
	let usedFiles: [URL]
	let onDocumentPickerToggle: (Bool) -> Void
	let onConfigurationChanged: (URL, UUID) -> Void

	var body: some View {
		List {
			Section {
				Text("Select a Create ML model supporting the object detection. Other models are not supported in this version.")
			} header: {
				EmptyView()
			} footer: {
				HStack {
					Spacer()
					Button(action: {
						onDocumentPickerToggle(true)
					}) {
						Image(systemName: "doc.badge.plus")
							.font(Font(.init(.label, size: 60.0)))
					}
					.buttonStyle(PressableButtonStyle())
					Spacer()
				}
			}

			Section {
				Link("Apple Documentation: Create ML", destination: URL(string: "https://developer.apple.com/documentation/createml")!)
			} header: {
				Text("Learn more about creating a detector in Create ML:")
					.font(.headline)
					.textCase(nil)
			}

			Section {
				Text("""
					import coremltools as ct

					# Load the ONNX model
					onnx_model = ct.onnx.load_model("path_to_your_model.onnx")

					# Convert the model
					coreml_model = ct.convert(onnx_model, source='onnx')

					# Save the converted model
					coreml_model.save("your_model.mlmodel")
					""")
					.font(.system(.body, design: .monospaced))
					.padding(.vertical)
			} header: {
				Text("Python Code to Convert ONNX to Create ML:").font(.headline)
					.font(.headline)
					.textCase(nil)
			}
		}
		.sheet(isPresented: .constant(showDocumentPicker)) {
			let newConfigurationId = UUID()
			DocumentPicker(usedURLs: usedFiles, configurationId: newConfigurationId) { url, id in
				onConfigurationChanged(url, id)
			}
		}
	}
}
