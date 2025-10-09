//
//  NewConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.11.23.
//

import Foundation
import SwiftUI

private enum ConfigurationSheet: Identifiable {
    case document
    case url
    var id: Int { hashValue }
}

struct NewConfigurationView: View {
	@EnvironmentObject var deep: DeepState
    @State private var activeSheet: ConfigurationSheet?
	let usedFiles: [URL]
	let onConfigurationChanged: (URL, UUID, ModelProvider) -> Void

	private static let pythonCode = """
		import coremltools as ct

		# Load the ONNX model
		onnx_model = ct.onnx.load_model("path_to_your_model.onnx")

		# Convert the model
		coreml_model = ct.convert(onnx_model, source='onnx')

		# Save the converted model
		coreml_model.save("your_model.mlmodel")
	"""

	var body: some View {
		List {
			Section {
				Text("Choose a Create ML model (.mlmodel or .mlpackage) that supports object detection. Other model types are not supported in this version.")
			} header: {
				EmptyView()
			} footer: {
                SourceButtons(activeSheet: $activeSheet)
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
				Text(Self.pythonCode)
					.font(.system(.body, design: .monospaced))
					.padding(.vertical)
					.copiedToClipboard(copiedText: Self.pythonCode, preview: String(Self.pythonCode.prefix(80)))
			} header: {
				Text("Python Code to Convert ONNX to Create ML:").font(.headline)
					.font(.headline)
					.textCase(nil)
			}
		}
		.onReceive(deep.$deepStateError) { error in
            print("🚨 DeepState error: \(String(describing: error))")
			guard error.isNotNil else { return }
		}
        .sheet(item: $activeSheet) { sheet in
            let newConfigurationId = UUID()
            switch sheet {
            case .document:
                DocumentPicker(usedURLs: usedFiles, configurationId: newConfigurationId) { url, id, provider in
                    onConfigurationChanged(url, id, provider)
                }
            case .url:
                DownloaderView(configurationId: newConfigurationId) { url, id, provider in
                    onConfigurationChanged(url, id, provider)
                }
            }
        }
        .onAppear {
            print("🟢 [NewConfigurationView] appeared")
        }
        .onDisappear {
            print("🔴 [NewConfigurationView] disappeared")
        }
	}
}

fileprivate struct SourceButtons: View {
    @Binding var activeSheet: ConfigurationSheet?
    
    var body: some View {
        HStack {
            Spacer()
            PlusIconButton(systemName: "doc") {
                if activeSheet == nil {
                    activeSheet = .document
                }
            }
            Spacer()
            PlusIconButton(systemName: "globe") {
                if activeSheet == nil {
                    activeSheet = .url
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

fileprivate struct PlusIconButton: View {
	var systemName: String
	var action: () -> Void

	var body: some View {
		Button(action: action) {
			ZStack(alignment: .bottomLeading) {
				Image(systemName: systemName)
					.resizable()
					.frame(width: 70, height: 70)
				ZStack {
					Circle()
						.frame(width: 37, height: 37)
						.foregroundColor(.blue)
					Image(systemName: "plus.circle.fill")
						.resizable()
						.frame(width: 30, height: 30)
				}
				.alignmentGuide(.bottom) { d in d[.bottom] }
				.alignmentGuide(.leading) { d in d[.leading] }
			}
		}
		.buttonStyle(PressableButtonStyle())
	}
}
