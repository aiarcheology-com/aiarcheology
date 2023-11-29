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
	@EnvironmentObject var deep: DeepState
	@State var showDocumentPicker: Bool = false
	let configuration: DeepConfiguration
	let usedFiles: [URL]
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
						showDocumentPicker = true
					}) {
						Image(systemName: "doc.badge.plus")
							.font(Font(.init(.label, size: 60.0)))
					}
					.buttonStyle(PressableButtonStyle())
					Spacer()
				}
				.padding(12)
			}

			Section {
				Link("Apple Documentation: Create ML", destination: URL(string: "https://developer.apple.com/documentation/createml")!)
			} header: {
				Text("Learn more about creating a detector in Create ML:")
					.font(.headline)
					.textCase(nil)
			}

			Section {
				Link("Get models on device using Core ML Converters", destination: URL(string: "https://developer.apple.com/videos/play/wwdc2020/10153/")!)
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
		.sheet(isPresented: $showDocumentPicker) {
			let newConfigurationId = UUID()
			DocumentPicker(usedURLs: usedFiles, configurationId: newConfigurationId) { url, id in
				onConfigurationChanged(url, id)
			}
		}
		.onReceive(deep.$deepStateError) { error in
			guard error.isNotNil else { return }
			showDocumentPicker = false
		}
	}
}
