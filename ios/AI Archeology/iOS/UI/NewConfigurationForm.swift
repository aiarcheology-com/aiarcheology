//
//  NewConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI

struct NewConfigurationView: View {
	let showDocumentPicker: Bool
	let configuration: DeepConfiguration
	let usedFiles: [URL]
	let onDocumentPickerToggle: (Bool) -> Void // Using callbacks as the compiler is not able to compile
	let onConfigurationChanged: (URL) -> Void  // these lines with normal @Binding's.

	var body: some View {
		EmptyView()
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
			DocumentPicker(usedURLs: usedFiles) { url in
				onConfigurationChanged(url)
			}
		}
	}
}

