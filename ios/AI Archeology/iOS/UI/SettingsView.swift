//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

	import SwiftUI

	struct SettingsForm: View {
		@Environment(\.dismiss) private var dismiss
		@EnvironmentObject var settings: Settings
		@EnvironmentObject var guide: Guide
		@State private var defaultWebPlaceholder: String = "www.google.com"
		@State private var validationErrorMessage: String?
		@State private var resetButtonColor: Color = .red
		@State private var showResetWarning = false

		var mergedObservable: [String] {[
			// Updated from the user's input:
			settings.snapFrequency.description,
			settings.snapAfterAppStart.description,
			settings.defaultPage?.description ?? "",
			settings.resetHistory.description,
		]}

		var body: some View {
			NavigationView {
				Form {
						// Detection Section
					Section(header: Text("Detection")) {
						Picker("Snapshot Frequency", selection: $settings.snapFrequency) {
							ForEach(1...10, id: \.self) { second in
								Text("\(second) second\(second > 1 ? "s" : "")").tag(Double(second))
							}
						}
						.onChange(of: settings.snapFrequency) { _ in
							guide.ontheflyDetectionResetTapped()
						}

						Toggle("Restart detection after application start", isOn: $settings.snapAfterAppStart)
					}

						// Web Content Section
					Section(header: Text("Web Content")) {
						HStack {
							Text("Default Web Page") // Label on the left
							Spacer()
							TextField(defaultWebPlaceholder, text: Binding(
								get: { settings.defaultPage?.absoluteString ?? "" },
								set: { newValue in
									settings.defaultPage = newValue.isEmpty ? nil : URL(string: newValue)
								}
							)) { changed in
								if changed {
									defaultWebPlaceholder = ""
								}
							}
							.multilineTextAlignment(.trailing)
							.foregroundColor(.gray)
						}
						Toggle("Reset browsing history on app restart", isOn: $settings.resetHistory)
					}
					Section(header: Text("ML Browser")) {
						HStack {
							Text("Reset to Default Settings")
							Spacer()
							Button(action: {
								showResetWarning = true
							}) {
								Text("Reset Application")
							}
							.buttonStyle(PressableButtonStyle(color: resetButtonColor))
						}
						.onChange(of: settings.applicationResetButtonToggle) { reseted in
							resetButtonColor = .blue
						}
						NavigationLink(destination: AppDescriptionView()) {
							HStack {
								Text("About the App")
							}
						}
					}
				}
				.navigationBarTitle("Settings")
				.navigationBarItems(trailing: Button(action: {
					do {
						try settings.validate()
						dismiss()
					} catch ValidationError.invalidData(let message) {
						validationErrorMessage = message
					} catch {
						validationErrorMessage = "An unexpected error occurred."
					}
				}) {

					Text("Dismiss").bold()
				})
				.alert(isPresented: .constant(validationErrorMessage != nil), content: {
					Alert(
						title: Text("Validation Error"),
						message: Text(validationErrorMessage ?? "An error occurred during validation."),
						dismissButton: .default(Text("OK"), action: {
							validationErrorMessage = nil // Reset the error message
						})
					)
				})
				.alert(isPresented: $showResetWarning) {
					Alert(
						title: Text("Warning"),
						message: Text("Resetting the application will erase all data models from the ML Browser. Are you sure you want to proceed?"),
						primaryButton: .destructive(Text("Reset"), action: guide.resetApplication),
						secondaryButton: .cancel()
					)
				}
				.onChange(of: mergedObservable) { _ in
					resetButtonColor = .red
				}
			}
		}
	}

struct AppDescriptionView: View {
	var body: some View {
		Text("Application Description Here...")
			.navigationBarTitle("About the App", displayMode: .inline)
	}
}
