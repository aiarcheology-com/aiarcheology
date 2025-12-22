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
					.testability(Testability.Picker.settingsFrequency)
					.onChange(of: settings.snapFrequency) {
						guide.ontheflyDetectionResetTapped()
					}

					Toggle("Run At Launch", isOn: $settings.snapAfterAppStart)
						.testability(Testability.Toggle.settingsRunAtLaunch)
					Toggle("Show Labels", isOn: $settings.showIdentifiers)
						.testability(Testability.Toggle.settingsShowLabels)
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
						.testability(Testability.TextField.settingsDefaultPage)
						.multilineTextAlignment(.trailing)
						.foregroundColor(.gray)
					}
					Toggle("Reopen Last Page", isOn: $settings.reopenLastPage)
						.testability(Testability.Toggle.settingsReopenLastPage)
					HStack {
						Text("History Limit")
							.foregroundColor(.primary)
						Spacer()
						TextField("0-100", value: $settings.historySize, formatter:
									NumberFormatter.historyLimitFormatter)
							.testability(Testability.TextField.settingsHistoryLimit)
							.multilineTextAlignment(.trailing)
							.keyboardType(.numberPad)
							.foregroundColor(.gray)
							.toolbar {
								ToolbarItemGroup(placement: .keyboard) {
									Spacer()
									Button("Done") {
										Self.removeFocus()
									}
									.testability(Testability.Button.settingsKeyboardDone)
								}
							}
					}
					NavigationLink(destination: BrowserHistoryView()
						.environment(\.dismissSheet, { dismiss() })
					) {
						HStack {
							Text("History")
						}
					}
					.testability(Testability.NavigationLink.settingsHistory)
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
						.testability(Testability.Button.settingsDeleteCache)
					}
					.onChange(of: settings.applicationResetButtonToggle) {
						resetButtonColor = .blue
					}
				}
				Section(header: Text("ML Browser")) {
					NavigationLink(destination: AppDescriptionView()
						.environment(\.dismissSheet, { dismiss() })) {
						HStack {
							Text("About")
						}
					}
					.testability(Testability.NavigationLink.settingsAbout)
					NavigationLink(destination: SlideshowView()
						.environmentObject(settings)
						.environment(\.dismissSheet, { dismiss() })) {
						HStack {
							Text("Introduction")
						}
					}
					.testability(Testability.NavigationLink.settingsIntroduction)
					HStack {
						Text("Restore Defaults")
						Spacer()
						Button(action: {
							self.alertItem = AlertItem(title: Text("Warning"),
													   message: Text("Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?"),
													   primaryButton: .destructive(Text("Restore"), action: {
														   Task {
															   await guide.resetApplication()
														   }
													   }),
													   secondaryButton: .cancel())
						}) {
							Text("Restore")
						}
						.testability(Testability.Button.settingsRestoreDefaults)
						.buttonStyle(PressableButtonStyle(color: resetButtonColor))
					}
					.onChange(of: settings.applicationResetButtonToggle) {
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

				Text("Dismiss")
					.bold()
					.foregroundColor(.blue)
			}
			.testability(Testability.Button.settingsDismiss)
			)

			.alert(isPresented: .constant(validationErrorMessage != nil), content: {
				Alert(
					title: Text("Validation Error"),
					message: Text(validationErrorMessage ?? "An error occurred during validation."),
					dismissButton: .default(Text("OK"), action: {
						validationErrorMessage = nil // Reset the error message
					})
				)
			})
			.onChange(of: mergedObservable) {
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

















