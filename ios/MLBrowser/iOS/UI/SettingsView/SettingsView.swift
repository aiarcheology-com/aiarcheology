//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

import SwiftUI

struct SettingsForm: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(DrawerManager.self) private var drawer
	@Environment(TourState.self) private var tour
	@EnvironmentObject var settings: Settings
	@EnvironmentObject var guide: Guide
	@EnvironmentObject var authState: AuthState
	@FocusState private var isHistoryLimitFocused: Bool
	@State private var defaultWebPlaceholder: String = "www.google.com"
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
		NavigationStack {
			Form {
				annotationSection
				webContentSection
				mlBrowserSection
				accountSection
				debugSection
			}
			.navigationBarTitle(L10n.Settings.title, displayMode: .inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(action: {
						do {
							try settings.validate()
							dismiss()
						} catch ValidationError.invalidData(let message) {
							self.alertItem = AlertItem(title: Text(L10n.Alert.Error.title),
													 message: Text(message),
													 dismissButton: .default(Text(L10n.Common.ok)))
						} catch {
							self.alertItem = AlertItem(title: Text(L10n.Alert.Error.title),
													  message: Text(L10n.Alert.Error.unexpected),
													  dismissButton: .default(Text(L10n.Common.ok)))
						}
					}) {
						Text(L10n.Common.dismiss)
							.bold()
							.foregroundColor(.blue)
					}
					.testability(Testability.Button.settingsDismiss)
				}
				
				ToolbarItemGroup(placement: .keyboard) {
					if isHistoryLimitFocused {
						Spacer()
						Button(L10n.Common.done) {
							isHistoryLimitFocused = false
						}
						.testability(Testability.Button.settingsKeyboardDone)
					}
				}
			}

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
			Picker(L10n.Settings.frequency, selection: $settings.snapFrequency) {
				ForEach(1...10, id: \.self) { second in
					Text(L10n.Settings.Frequency.seconds(second)).tag(Double(second))
				}
			}
			.testability(Testability.Picker.settingsFrequency)
			.onChange(of: settings.snapFrequency) {
				guide.ontheflyDetectionResetTapped()
			}

			Toggle(L10n.Settings.runAtLaunch, isOn: $settings.snapAfterAppStart)
				.testability(Testability.Toggle.settingsRunAtLaunch)
			Toggle(L10n.Settings.showLabels, isOn: $settings.showIdentifiers)
				.testability(Testability.Toggle.settingsShowLabels)
			Toggle(L10n.Settings.tiledDetection, isOn: $settings.tiledDetection)
				.testability(Testability.Toggle.settingsTiledDetection)
			Toggle(L10n.Settings.fullscreenDetection, isOn: $settings.fullscreenDetection)
				.testability(Testability.Toggle.settingsFullscreenDetection)
				.onChange(of: settings.fullscreenDetection) {
					// Apply to a detection that is already running.
					guide.fullscreenDetectionSettingChanged()
				}
		}
	}

	private var webContentSection: some View {
		Section(header: Text(L10n.Settings.Section.webContent)) {
			HStack {
				Text(L10n.Settings.defaultPage)
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
			Toggle(L10n.Settings.reopenLastPage, isOn: $settings.reopenLastPage)
				.testability(Testability.Toggle.settingsReopenLastPage)
			historyLimitRow
			NavigationLink(destination: BrowserHistoryView()
				.environment(\.dismissSheet, { dismiss() })
			) {
				Text(L10n.Settings.history)
			}
			.testability(Testability.NavigationLink.settingsHistory)
			deleteCacheRow
		}
	}

	private var historyLimitRow: some View {
		HStack {
			Text(L10n.Settings.historyLimit)
				.foregroundColor(.primary)
			Spacer()
			TextField("0-100", value: $settings.historySize, formatter: NumberFormatter.historyLimitFormatter)
				.testability(Testability.TextField.settingsHistoryLimit)
				.multilineTextAlignment(.trailing)
				.keyboardType(.numberPad)
				.foregroundColor(.gray)
				.focused($isHistoryLimitFocused)
		}
	}

	private var deleteCacheRow: some View {
		HStack {
			Text(L10n.Settings.deleteCache)
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
			replayOnboardingRow
			restoreDefaultsRow
		}
	}

	/// Replays the interactive onboarding tour (AIA-0333). Dismisses Settings and closes the
	/// drawer first so the tour's first step (the address bar) is visible underneath.
	private var replayOnboardingRow: some View {
		// A plain tappable row rather than a `Button`: the list-button style rendered the label
		// gray (and overrode `.foregroundStyle`), while `.buttonStyle(.plain)` shrank the tap
		// target. A `Text` row + full-width `.contentShape` + `.onTapGesture` keeps the standard
		// primary label color and a full-row tap (AIA-0333).
		HStack {
			Text(L10n.Settings.replayOnboarding)
			Spacer()
		}
		.contentShape(Rectangle())
		.onTapGesture {
			dismiss()
			drawer.close()
			tour.start()
		}
		.accessibilityAddTraits(.isButton)
		.testability(Testability.Button.settingsReplayOnboarding)
	}

	private var restoreDefaultsRow: some View {
		HStack {
			Text(L10n.Settings.restoreDefaults)
			Spacer()
			Button(action: {
				self.alertItem = AlertItem(
					title: Text(L10n.Alert.Warning.title),
					message: Text(L10n.Alert.Restore.message),
					primaryButton: .destructive(Text(L10n.Settings.restore), action: {
						Task {
							await guide.resetApplication()
						}
					}),
					secondaryButton: .cancel()
				)
			}) {
				Text(L10n.Settings.restore)
			}
			.testability(Testability.Button.settingsRestoreDefaults)
			.buttonStyle(PressableButtonStyle(color: resetButtonColor))
		}
		.onChange(of: settings.applicationResetButtonToggle) {
			resetButtonColor = .blue
		}
	}

	/// Account management (AIA-0340): sign out and the App Store-required
	/// in-app account deletion (Apple Guideline 5.1.1(v)).
	private var accountSection: some View {
		Section(header: Text(L10n.Auth.Account.title)) {
			Button(role: .none) {
				Task { await authState.signOut() }
			} label: {
				Text(L10n.Auth.signOut)
			}
			.testability(Testability.Button.settingsSignOut)

			Button(role: .destructive) {
				self.alertItem = AlertItem(
					title: Text(L10n.Auth.Account.Delete.title),
					message: Text(L10n.Auth.Account.Delete.message),
					primaryButton: .destructive(Text(L10n.Auth.Account.Delete.action), action: {
						Task { try? await authState.deleteAccount() }
					}),
					secondaryButton: .cancel()
				)
			} label: {
				Text(L10n.Auth.Account.Delete.action)
			}
			.testability(Testability.Button.settingsDeleteAccount)
		}
		.foregroundColor(.primary)
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
