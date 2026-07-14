//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

import SwiftUI
import ClerkKit
import ClerkKitUI

/// Navigation routes pushed onto the Settings stack (AIA-0340).
private enum AccountRoute: Hashable {
	case profile
	case subscription
}

struct SettingsForm: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(DrawerManager.self) private var drawer
	@Environment(TourState.self) private var tour
	@EnvironmentObject var settings: Settings
	@EnvironmentObject var chromeState: AppChromeState
	@EnvironmentObject var detectionState: DetectionSessionState
	@EnvironmentObject var subscriptionState: SubscriptionState
	/// Real vs. mock auth from the composition root (AIA-0385). Re-injected onto this sheet in
	/// `DrawerContent` because custom env values don't cross the sheet boundary on Mac/iPad.
	@Environment(\.usesRealAuth) private var usesRealAuth
	@FocusState private var isHistoryLimitFocused: Bool
	/// Drives the Settings navigation stack so the embedded Clerk profile pushes onto it.
	@State private var accountPath = NavigationPath()
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
		NavigationStack(path: $accountPath) {
			Form {
				annotationSection
				webContentSection
				mlBrowserSection
				accountSection
				debugSection
			}
			.navigationDestination(for: AccountRoute.self) { route in
				switch route {
				case .profile:
					// Embedded on the Settings stack (shares `accountPath`), so the profile's
					// own Manage-account / Security sub-screens resolve correctly.
					UserProfileView(isDismissible: false, navigationPath: $accountPath)
						.environment(Clerk.shared)
						.environment(\.clerkTheme, .app)
				case .subscription:
					SubscriptionStatusView(subscriptionState: subscriptionState)
				}
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
				detectionState.ontheflyDetectionResetTapped()
			}

			Toggle(L10n.Settings.runAtLaunch, isOn: $settings.snapAfterAppStart)
				.testability(Testability.Toggle.settingsRunAtLaunch)
			Toggle(L10n.Settings.showLabels, isOn: $settings.showIdentifiers)
				.testability(Testability.Toggle.settingsShowLabels)
			NavigationLink(destination: TiledDetectionSettingsView()) {
				Text(L10n.Settings.tiledDetection)
			}
			.testability(Testability.NavigationLink.settingsTiledDetection)
			Toggle(L10n.Settings.fullscreenDetection, isOn: $settings.fullscreenDetection)
				.testability(Testability.Toggle.settingsFullscreenDetection)
				.onChange(of: settings.fullscreenDetection) {
					// Apply to a detection that is already running.
					detectionState.fullscreenDetectionSettingChanged()
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
							await chromeState.resetApplication()
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

	/// Account management (AIA-0340). "Manage Account" opens Clerk's prebuilt
	/// `UserProfileView`, which handles change password, email, security/MFA,
	/// devices, and the App Store-required account deletion (Apple 5.1.1(v)).
	private var accountSection: some View {
		Section(header: Text(L10n.Auth.Account.title)) {
			if usesRealAuth, let email = Clerk.shared.user?.primaryEmailAddress?.emailAddress {
				HStack {
					Text(email)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
					Spacer()
				}
			}

			// Subscription (AIA-0343). When subscribed, tapping pushes the status submenu
			// (status + manage/cancel via Apple + restore + refund). Otherwise a static row.
			if FeatureFlags.isPaymentsEnabled && subscriptionState.isSubscribed {
				NavigationLink(value: AccountRoute.subscription) {
					HStack {
						Text(L10n.Auth.Account.subscription)
						Spacer()
						Text(subscriptionState.isInTrial ? L10n.Subscription.trial : L10n.Paywall.active)
							.foregroundColor(.secondary)
					}
				}
				.testability(Testability.NavigationLink.settingsSubscription)
			} else {
				HStack {
					Text(L10n.Auth.Account.subscription)
					Spacer()
					// Payments on but no entitlement (e.g. a lapse/refund before the gate
					// refreshes) → "Not subscribed". Payments off → the "Free Beta" label.
					Text(FeatureFlags.isPaymentsEnabled ? L10n.Subscription.notSubscribed : L10n.Auth.Account.freeBeta)
						.foregroundColor(.secondary)
				}
			}

			if usesRealAuth {
				// Push Clerk's profile onto the Settings stack (not a sheet): Settings is
				// itself a sheet, and a sheet-over-a-sheet presents-then-auto-dismisses.
				// Value-based push so UserProfileView and its own sub-screens (Manage
				// account / Security) all navigate on the SAME path — see the matching
				// `.navigationDestination` on the Form. (A closure NavigationLink would
				// push the profile off-path, and its sub-rows would fail to resolve.)
				NavigationLink(value: AccountRoute.profile) {
					Text(L10n.Auth.Account.manage)
				}
				.testability(Testability.NavigationLink.settingsManageAccount)
			}
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
				Toggle(L10n.Settings.tiledBorders, isOn: $settings.tiledBorders)
					.testability(Testability.Toggle.settingsTiledBorders)
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
