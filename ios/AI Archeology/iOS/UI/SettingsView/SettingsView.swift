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
	@State private var cleanCacheButtonColor: Color = .red
	@State private var alertItem: AlertItem?

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
				Section(header: Text("Annotation")) {
					Picker("Frequency", selection: $settings.snapFrequency) {
						ForEach(1...10, id: \.self) { second in
							Text("\(second) second\(second > 1 ? "s" : "")").tag(Double(second))
						}
					}
					.onChange(of: settings.snapFrequency) { _ in
						guide.ontheflyDetectionResetTapped()
					}

					Toggle("Run At Launch", isOn: $settings.snapAfterAppStart)
					Toggle("Show Labels", isOn: $settings.showIdentifiers)
				}

					// Web Content Section
				Section(header: Text("Web Content")) {
					HStack {
						Text("Default Page") // Label on the left
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
					Toggle("Reopen Last Page", isOn: $settings.reopenLastPage)
					HStack {
						Text("History Limit")
							.foregroundColor(.primary)
						Spacer()
						TextField("0-100", value: $settings.historySize, formatter:
									NumberFormatter.historyLimitFormatter)
							.multilineTextAlignment(.trailing)
							.keyboardType(.numberPad)
							.foregroundColor(.gray)
							.toolbar {
								ToolbarItemGroup(placement: .keyboard) {
									Spacer()
									Button("Done") {
										Self.removeFocus()
									}
								}
							}
					}
					NavigationLink(destination: BrowserHistoryView()) {
						HStack {
							Text("History")
						}
					}
					HStack {
						Text("Delete Cache")
						Spacer()
						Button(action: {
							WebCacheCleaner.clean()
							cleanCacheButtonColor = .blue
						}) {
							Text("Delete")
								.bold()
								.foregroundColor(cleanCacheButtonColor)
						}
					}
					.onChange(of: settings.applicationResetButtonToggle) { reseted in
						resetButtonColor = .blue
					}
				}
				Section(header: Text("ML Browser")) {
					NavigationLink(destination: AppDescriptionView()) {
						HStack {
							Text("About")
						}
					}
					NavigationLink(destination: SlideshowView().environmentObject(settings)) {
						HStack {
							Text("Introduction")
						}
					}
					HStack {
						Text("Restore Defaults")
						Spacer()
						Button(action: {
							self.alertItem = AlertItem(title: Text("Warning"),
													   message: Text("Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?"),
													   primaryButton: .destructive(Text("Restore"), action: guide.resetApplication),
													   secondaryButton: .cancel())
						}) {
							Text("Restore")
						}
						.buttonStyle(PressableButtonStyle(color: resetButtonColor))
					}
					.onChange(of: settings.applicationResetButtonToggle) { reseted in
						resetButtonColor = .blue
					}
				}
			}
			.navigationBarTitle("Settings", displayMode: .inline)
			.navigationBarItems(trailing: Button(action: {
				do {
					try settings.validate()
					dismiss()
				} catch ValidationError.invalidData(let message) {
					validationErrorMessage = message
					self.alertItem = AlertItem(title: Text("Error"),
											 message: Text(validationErrorMessage ?? ""), //TODO optional
											 dismissButton: .default(Text("OK"), action: { validationErrorMessage = nil }))
				} catch {
					validationErrorMessage = "An unexpected error occurred."
					self.alertItem = AlertItem(title: Text("Error"),
											  message: Text(validationErrorMessage ?? ""), //TODO optional
											  dismissButton: .default(Text("OK"), action: { validationErrorMessage = nil }))
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
			.onChange(of: mergedObservable) { _ in
				resetButtonColor = .red
			}
			.alert(item: $alertItem) { alertItem in
				if let primaryButton = alertItem.primaryButton, let secondaryButton = alertItem.secondaryButton {
					return Alert(title: alertItem.title,
								 message: alertItem.message,
								 primaryButton: primaryButton,
								 secondaryButton: secondaryButton)
				}
				if let dismissButton = alertItem.dismissButton {
					return Alert(title: alertItem.title,
								 message: alertItem.message,
								 dismissButton: dismissButton)
				}
				return Alert(title: alertItem.title,
							 message: alertItem.message)
			}
		}
	}
}

















