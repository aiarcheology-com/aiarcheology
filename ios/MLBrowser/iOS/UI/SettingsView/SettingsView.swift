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
		settings.resetHistory.description
	]}

	var body: some View {
		NavigationView {
			Form {
				annotationSection
				webContentSection
				mlBrowserSection
				debugSection
			}
			.navigationBarTitle(L10n.Settings.title, displayMode: .inline)
			.navigationBarItems(trailing: Button(action: {
				do {
					try settings.validate()
					dismiss()
				} catch ValidationError.invalidData(let message) {
					validationErrorMessage = message
					self.alertItem = AlertItem(title: Text(L10n.Alert.Error.title),
											 message: Text(validationErrorMessage ?? ""), // TODO optional
											 dismissButton: .default(Text(L10n.Common.ok), action: { validationErrorMessage = nil }))
				} catch {
					validationErrorMessage = "An unexpected error occurred."
					self.alertItem = AlertItem(title: Text(L10n.Alert.Error.title),
											  message: Text(validationErrorMessage ?? ""), // TODO optional
											  dismissButton: .default(Text(L10n.Common.ok), action: { validationErrorMessage = nil }))
				}
			}) {

				Text(L10n.Common.dismiss)
					.bold()
					.foregroundColor(.blue)
			}
			.testability(Testability.Button.settingsDismiss)
			)

			.alert(isPresented: .constant(validationErrorMessage != nil), content: {
				Alert(
					title: Text(L10n.Alert.Error.title),
					message: Text(validationErrorMessage ?? "An error occurred during validation."),
					dismissButton: .default(Text(L10n.Common.ok), action: {
						validationErrorMessage = nil // Reset the error message
					})
				)
			})
			.onChange(of: mergedObservable) {
				resetButtonColor = .red
			}
			.alert(item: $alertItem) { item in
				Self.createAlert(from: item)
			}
		}
	}

	// MARK: - Sections

	private var annotationSection: some View {
		Section(header: Text(L10n.Settings.Section.annotation)) {
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
	}

	private var webContentSection: some View {
		Section(header: Text(L10n.Settings.Section.webContent)) {
			HStack {
				Text("Default Page")
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
			historyLimitRow
			NavigationLink(destination: BrowserHistoryView()
				.environment(\.dismissSheet, { dismiss() })
			) {
				Text("History")
			}
			.testability(Testability.NavigationLink.settingsHistory)
			deleteCacheRow
		}
	}

	private var historyLimitRow: some View {
		HStack {
			Text("History Limit")
				.foregroundColor(.primary)
			Spacer()
			TextField("0-100", value: $settings.historySize, formatter: NumberFormatter.historyLimitFormatter)
				.testability(Testability.TextField.settingsHistoryLimit)
				.multilineTextAlignment(.trailing)
				.keyboardType(.numberPad)
				.foregroundColor(.gray)
				.toolbar {
					ToolbarItemGroup(placement: .keyboard) {
						Spacer()
						Button(L10n.Common.done) {
							Self.removeFocus()
						}
						.testability(Testability.Button.settingsKeyboardDone)
					}
				}
		}
	}

	private var deleteCacheRow: some View {
		HStack {
			Text("Delete Cache")
			Spacer()
			Button(action: {
				WebCacheCleaner.clean()
				cleanCacheButtonColor = .blue
			}) {
				Text(L10n.Common.delete)
					.bold()
					.foregroundColor(cleanCacheButtonColor)
			}
			.testability(Testability.Button.settingsDeleteCache)
		}
		.onChange(of: settings.applicationResetButtonToggle) {
			resetButtonColor = .blue
		}
	}

	private var mlBrowserSection: some View {
		Section(header: Text(L10n.Settings.Section.mlBrowser)) {
			NavigationLink(destination: AppDescriptionView()
				.environment(\.dismissSheet, { dismiss() })) {
				Text(L10n.Settings.about)
			}
			.testability(Testability.NavigationLink.settingsAbout)
			NavigationLink(destination: SlideshowView()
				.environmentObject(settings)
				.environment(\.dismissSheet, { dismiss() })) {
				Text(L10n.Settings.introduction)
			}
			.testability(Testability.NavigationLink.settingsIntroduction)
			restoreDefaultsRow
		}
	}

	private var restoreDefaultsRow: some View {
		HStack {
			Text("Restore Defaults")
			Spacer()
			Button(action: {
				self.alertItem = AlertItem(
					title: Text(L10n.Alert.Warning.title),
					message: Text("Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?"),
					primaryButton: .destructive(Text("Restore"), action: {
						Task {
							await guide.resetApplication()
						}
					}),
					secondaryButton: .cancel()
				)
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

	@ViewBuilder
	private var debugSection: some View {
		if AppEnvironment.isAppStoreDistribution.not {
			Section(header: Text(L10n.Settings.Section.debug)) {
				NavigationLink(destination: SentryStatsView()) {
					Text(L10n.Settings.Sentry.title)
				}
			}
		}
	}

	// MARK: - Helpers

	private static func createAlert(from alertItem: AlertItem) -> Alert {
		if let primaryButton = alertItem.primaryButton,
		   let secondaryButton = alertItem.secondaryButton {
			return Alert(
				title: alertItem.title,
				message: alertItem.message,
				primaryButton: primaryButton,
				secondaryButton: secondaryButton
			)
		}
		if let dismissButton = alertItem.dismissButton {
			return Alert(
				title: alertItem.title,
				message: alertItem.message,
				dismissButton: dismissButton
			)
		}
		return Alert(
			title: alertItem.title,
			message: alertItem.message
		)
	}
}
