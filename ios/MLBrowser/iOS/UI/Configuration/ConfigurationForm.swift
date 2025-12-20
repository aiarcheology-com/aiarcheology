//
//  ConfigurationForm.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 15.11.23.
//

import SwiftUI
import CoreML

// MARK: - Supporting Views

struct ConfigurationDetailRow: View {
	var label: String
	var value: String

	var body: some View {
		HStack {
			Text(label)
				.foregroundColor(.primary)
				.fontWeight(.regular)

			Spacer()

			Text(value)
				.foregroundColor(.gray)
				.lineLimit(1)
				.truncationMode(.tail)
		}
	}
}

struct ExpandableDetailRow: View {
	var label: String
	var value: String
	@State private var isExpanded: Bool = false
	@State private var isCopied: Bool = false

	var body: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading, spacing: 8) {
				Text(label)
					.foregroundColor(.primary)
					.fontWeight(.regular)

				if isExpanded {
					Button(action: {
						UIPasteboard.general.string = value
						isCopied = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
						isCopied = false
					}
					}) {
						Image(systemName: "document.on.document")
							.foregroundColor(isCopied ? .green : .blue)
							.font(.title3)
					}
					.testability(Testability.Button.configurationExapandableRow)
					.buttonStyle(.borderless)
				}
			}

			Spacer()

			Text(value)
				.foregroundColor(.gray)
				.lineLimit(isExpanded ? nil : 1)
				.truncationMode(.tail)
				.multilineTextAlignment(.trailing)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if !isExpanded {
				withAnimation(.easeInOut(duration: 0.2)) {
					isExpanded = true
				}
			}
		}
	}
}

struct LabeledSlider: View {
	var label: String
	@Binding var value: Double
	var range: ClosedRange<Double>
	
	var body: some View {
		VStack(alignment: .leading) {
			let formattedValue = String(format: "%.2f", value)
			ConfigurationDetailRow(label: label, value: formattedValue)
				.foregroundColor(.primary)
				.fontWeight(.regular)
			
			Slider(value: $value, in: range)
				.testability(Testability.Slider.configurationFormFadeOutTime)
		}
	}
}

// MARK: - Configuration Form

/// Form for viewing and editing an existing ML model configuration.
struct ConfigurationForm: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject var deep: DeepState
	@EnvironmentObject var configuration: DeepConfiguration
	
	private var mergedObservable: [String] {[
		configuration.annotationColor.description,
		configuration.phaseOutTime.description,
		configuration.selectedSymbol.rawValue
	]}
	
	var body: some View {
		NavigationStack {
			Form {
				modelSection
				authorSection
				annotationSection
			}
			.onChange(of: mergedObservable) {
				deep.saveConfigurations()
			}
			.navigationBarTitle("Configuration", displayMode: .inline)
			.navigationBarItems(trailing: doneButton)
		}
	}
	
	// MARK: - Sections
	
	private var modelSection: some View {
		Section(header: Text("Model")) {
			ConfigurationDetailRow(label: "File", value: "\(configuration.file?.pathComponents.last ?? "")")
			ConfigurationDetailRow(label: "Description", value: " \(configuration.modelDescription ?? "")")
			ConfigurationDetailRow(label: "Type", value: " \(configuration.modelType.rawValue)")
			ConfigurationDetailRow(label: "Version", value: " \(configuration.modelVersion ?? "")")

			if let downloadURL = configuration.downloadURL {
				ExpandableDetailRow(label: "Link", value: downloadURL.absoluteString)
			}
		}
	}
	
	private var authorSection: some View {
		Section(header: Text("Author")) {
			ConfigurationDetailRow(label: "Author", value: "\(configuration.author ?? "")")
			ConfigurationDetailRow(label: "Created", value: "\(configuration.creationDate)")
		}
	}
	
	private var annotationSection: some View {
		Section(header: Text("Annotation")) {
			ColorPicker("Color", selection: $configuration.annotationColor)
				.testability(Testability.ColorPicker.configurationFormAnnotationColor)
			LabeledSlider(label: "Fade Out Time", value: $configuration.phaseOutTime, range: 0.2...10)
			Picker("Symbol", selection: $configuration.selectedSymbol) {
				ForEach(AnnotationSymbol.allCases) { symbol in
					Text(symbol.rawValue).tag(symbol)
				}
			}
			.testability(Testability.Picker.configurationFormSymbol)
		}
	}
	
	// MARK: - Navigation
	
	private var doneButton: some View {
		Button(action: {
			deep.saveConfigurations()
			dismiss()
		}) {
			Text("Done").bold()
		}
		.testability(Testability.Button.configurationFormDone)
		.tint(.green)
	}
}

// MARK: - Button Style

struct PressableButtonStyle: ButtonStyle {
	var color: Color = .blue
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundColor(.white)
			.padding(9)
			.background(configuration.isPressed ? color.opacity(0.5) : color)
			.cornerRadius(10)
			.shadow(radius: configuration.isPressed ? 5 : 10)
			.scaleEffect(configuration.isPressed ? 0.9 : 1.0)
			.animation(.spring(response: 0.3, dampingFraction: 0.5, blendDuration: 0), value: configuration.isPressed)
	}
}
