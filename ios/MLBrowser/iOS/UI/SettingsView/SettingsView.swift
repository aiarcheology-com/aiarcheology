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
	/// The findings persistence repository (AIA-0303), used by the Reset section's "Remove
	/// Findings" action to delete all findings and to snapshot them for export. Passed by
	/// initializer (it is not an `ObservableObject`), from `DrawerContent`.
	let findingRepository: FindingRepository

	@Environment(\.dismiss) private var dismiss
	@Environment(DrawerManager.self) private var drawer
	@Environment(TourState.self) private var tour
	@EnvironmentObject var settings: Settings
	@EnvironmentObject var chromeState: AppChromeState
	@EnvironmentObject var detectionState: DetectionSessionState
	@EnvironmentObject var subscriptionState: SubscriptionState
	@EnvironmentObject var analytics: AnalyticsState
	/// Remote Settings-surface messages (AIA-0115). Observed directly, like in `AppDescriptionView`,
	/// because a nested `ObservableObject` does not republish through `AppState`.
	@EnvironmentObject private var messageCenter: MessageCenterState
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

	// Remove Findings (AIA-0303). The confirmation dialog offers Export / Delete / Cancel as
	// independent choices; exporting never deletes (the user re-opens to delete).
	@State private var showRemoveFindings = false
	/// True while the export ZIP is being built (before the share sheet appears). Only fades the
	/// row's spinner and dims/disables its button — never restructures the row, because restructuring
	/// it while the share sheet is up wedges the sheet's dismissal on iOS-on-Mac (AIA-0448).
	@State private var isExportingFindings = false
	@State private var findingsSharePayload: ActivitySharePayload?

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
				// Remotely-delivered informational messages targeted at the Settings surface, pinned
				// above the regular sections — only when the server actually delivered some.
				if !messageCenter.settingsMessages.isEmpty {
					messagesSection
				}
				annotationSection
				privacySection
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
			// The findings-export share sheet stays at the root NavigationStack: its presenter
			// (a `.background` UIViewControllerRepresentable) must outlive the user popping the
			// pushed Reset screen mid-export, since the ZIP builds after a delay (AIA-0402/0448).
			.activityShareSheet($findingsSharePayload)
		}
	}

	@ViewBuilder
	private var privacySection: some View {
		if analytics.isAnalyticsFeatureEnabled {
			Section(header: Text(L10n.Analytics.Settings.title), footer: Text(L10n.Analytics.Settings.footer)) {
				Toggle(L10n.Analytics.Settings.toggle, isOn: Binding(
					get: { settings.analyticsEnabled },
					set: { analytics.setAnalyticsEnabled($0) }
				))
				.testability(Testability.Toggle.settingsAnalytics)
			}
		}
	}

	// MARK: - Sections

	private var messagesSection: some View {
		Section {
			ForEach(messageCenter.settingsMessages, id: \.id) { message in
				AppMessageInlineRow(
					message: message,
					languageCode: AppMessage.deviceLanguageCode,
					testabilityLabel: .appMessageSettingsRow
				)
			}
		}
	}

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
			Toggle(L10n.Settings.disableDetectionAnimations, isOn: $settings.disableDetectionAnimations)
				.testability(Testability.Toggle.settingsDisableDetectionAnimations)
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
			NavigationLink(destination: resetOptionsView) {
				Text(L10n.Settings.Reset.title)
			}
			.testability(Testability.NavigationLink.settingsReset)
		}
	}

	/// The Reset actions, reached via the "Reset" entry in the ML Browser section. "Remove Findings"
	/// (delete all findings + their photos, with an export-first offer) and "Restore Defaults" (does
	/// NOT touch findings) stay two independent, individually confirmation-guarded actions. The
	/// Remove Findings confirmation alert lives on THIS pushed screen (a boolean `.alert` attached at
	/// the root does not present when fired from a pushed view); the export share sheet and the
	/// error/Restore `alertItem` stay at the root `NavigationStack` so their presenters outlive a push
	/// (AIA-0303/0448/0402).
	private var resetOptionsView: some View {
		Form {
			Section {
				removeFindingsRow
				restoreDefaultsRow
			}
		}
		.navigationBarTitle(L10n.Settings.Reset.title, displayMode: .inline)
		// Remove Findings confirmation (AIA-0303): attached at THIS pushed screen's content level —
		// where the trigger row lives. A boolean `.alert` attached at the root NavigationStack does
		// NOT present when fired from a pushed view (only the item-based `alertItem` does), and a
		// row-level presentation is unreliable. `.alert` not `.confirmationDialog` (which did not
		// present from this sheet-hosted Form). The export share sheet stays at the root (see `body`).
		.alert(
			L10n.Settings.Reset.RemoveFindings.title,
			isPresented: $showRemoveFindings
		) {
			// Only offer export when there is something to export.
			if findingRepository.hasAnyFinding() {
				Button(L10n.Settings.Reset.RemoveFindings.export) {
					exportFindingsBeforeRemoval()
				}
				.testability(Testability.Button.settingsRemoveFindingsExport)
			}
			Button(L10n.Settings.Reset.RemoveFindings.delete, role: .destructive) {
				removeAllFindings()
			}
			.testability(Testability.Button.settingsRemoveFindingsConfirm)
			Button(L10n.Common.cancel, role: .cancel) {}
		} message: {
			Text(L10n.Settings.Reset.RemoveFindings.message)
		}
	}

	/// Deletes every saved finding and its screenshot, guarded by a confirmation alert that also
	/// offers to export first. Export and delete are separate explicit choices — exporting returns
	/// to Settings without deleting; the user re-opens the alert to delete (AIA-0303). The alert
	/// itself lives at the NavigationStack-content level (see `body`); this row only triggers it.
	private var removeFindingsRow: some View {
		HStack {
			Text(L10n.Settings.Reset.RemoveFindings.row)
			Spacer()
			// Spinner is ALWAYS in the tree and only faded, and the button stays put with just its
			// `.disabled` attribute toggled — no view is inserted/removed on this row while the
			// share sheet is presented from it (AIA-0448 structural-churn class).
			ProgressView()
				.opacity(isExportingFindings ? 1 : 0)
				.accessibilityHidden(true)
			// A prominent red button (PressableButtonStyle), matching Restore Defaults — but NOT
			// `Button(role: .destructive)`: a destructive-role button inside a Form row is treated
			// specially and its tap did not open the dialog (AIA-0303). The destructive semantics
			// live on the alert's "Delete" action instead.
			Button {
				showRemoveFindings = true
			} label: {
				Text(L10n.Settings.Reset.RemoveFindings.button)
			}
			.buttonStyle(PressableButtonStyle(color: .red))
			// PressableButtonStyle has no disabled state, so dim the filled button while exporting.
			.opacity(isExportingFindings ? 0.5 : 1)
			.disabled(isExportingFindings)
			.testability(Testability.Button.settingsRemoveFindings)
		}
	}

	/// Builds a ZIP of all findings and hands it to the share sheet — WITHOUT deleting. The zip is
	/// built detached; the payload is handed to the presenter one beat AFTER the confirmation dialog
	/// has finished dismissing, so a fast (e.g. single-finding) export cannot hit the
	/// "present while dismissing" no-op that would silently drop the share sheet (AIA-0402).
	private func exportFindingsBeforeRemoval() {
		let snapshots = findingRepository.allFindingSnapshots()
		isExportingFindings = true
		Task {
			defer { isExportingFindings = false }
			do {
				let url = try await Task.detached(priority: .userInitiated) {
					try FindingExporter.makeZip(from: snapshots)
				}.value
				// Outlast the confirmation alert's dismissal animation before presenting (AIA-0402).
				try? await Task.sleep(for: .milliseconds(500))
				findingsSharePayload = ActivitySharePayload(items: [url])
			} catch {
				LoggingPolicy.error("Failed to export findings before removal", error: error, logger: .storage)
				showRemoveFindingsError(L10n.Findings.Export.error)
			}
		}
	}

	/// Permanently deletes all findings and their screenshots (AIA-0303).
	private func removeAllFindings() {
		Task {
			do {
				try await findingRepository.removeAllFindings()
			} catch {
				LoggingPolicy.error("Failed to remove all findings", error: error, logger: .storage)
				showRemoveFindingsError(L10n.Settings.Reset.RemoveFindings.error)
			}
		}
	}

	/// Surfaces a Remove Findings failure through the existing settings alert (AIA-0303).
	private func showRemoveFindingsError(_ message: String) {
		alertItem = AlertItem(
			title: Text(L10n.Alert.Error.title),
			message: Text(message),
			dismissButton: .default(Text(L10n.Common.ok))
		)
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
			if subscriptionState.isPaymentsSurfaceEnabled && subscriptionState.isSubscribed {
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
					Text(subscriptionState.isPaymentsSurfaceEnabled ? L10n.Subscription.notSubscribed : L10n.Auth.Account.freeBeta)
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
