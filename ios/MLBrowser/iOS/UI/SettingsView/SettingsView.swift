//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

import SwiftUI
import StoreKit
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

	/// Auth, for the account section (AIA-0536). Sign-in is optional under the paywall-first gate
	/// order, so signed-out is a state Settings must render rather than one it can assume away.
	@ObservedObject var authState: AuthState

	/// When the app-managed free window runs out, or `nil` when none is open (AIA-0556).
	///
	/// A plain `Date?` rather than the whole `FreeAccessState`: Settings only needs to state the
	/// date, and it cannot change while this sheet is up — the expiry is frozen at grant. Passed by
	/// initializer for the same reason `findingRepository` is.
	var freeAccessEndsOn: Date?

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

	/// Contextual sign-in, offered from the account section when signed out (AIA-0536).
	@State private var showSignIn = false

	/// The paywall, opened from the Subscription row while nothing is owned (AIA-0556).
	@State private var showPaywall = false

	/// Whether *this* Apple Account would still get the introductory free trial, or `nil` until
	/// StoreKit has said — the paywall's three-valued rule (see `PaywallView.introOfferEligibility`),
	/// borrowed so the account footer never promises a trial to a returning user (AIA-0562).
	@State private var introOfferEligibility: Bool?
	@FocusState private var isHistoryLimitFocused: Bool
	/// Drives the Settings navigation stack so the embedded Clerk profile pushes onto it.
	@State private var accountPath: NavigationPath

	/// `startAtManageAccount` seeds the stack **at birth**, not in `onAppear` (AIA-0536): mutating a
	/// `NavigationPath` while the sheet's first-ever presentation is still installing the stack gets
	/// silently dropped, so the drawer's deep link worked on every open except the one that mattered.
	/// A path the stack is born with has no timing to lose. A `Bool` rather than the route because
	/// `AccountRoute` is private to this file; the *validity* guards (validated account, real auth)
	/// live with the caller, which is the only party that can consult them at tap time.
	init(
		findingRepository: FindingRepository,
		authState: AuthState,
		freeAccessEndsOn: Date? = nil,
		startAtManageAccount: Bool = false
	) {
		self.findingRepository = findingRepository
		self._authState = ObservedObject(wrappedValue: authState)
		self.freeAccessEndsOn = freeAccessEndsOn
		var path = NavigationPath()
		if startAtManageAccount { path.append(AccountRoute.profile) }
		self._accountPath = State(initialValue: path)
	}
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
			// Keyed on the loaded product, so this runs again if the products arrive from anywhere
			// else — the paywall sheet presented from this same screen loads them too. A one-shot
			// task that ran while the list was still empty would leave eligibility unresolved for
			// the life of the sheet, leaving the date-only footer standing next to a paywall that
			// is offering the trial.
			.task(id: subscriptionState.products.first?.id) {
				// Resolve what the account footer may promise (AIA-0562/0576): the product's trial
				// offer and this Apple Account's eligibility for it — the same off-the-launch-path
				// fetch the paywall runs. Gated to exactly the state that renders the free-access
				// footnote, so every other Settings visit skips the StoreKit round trip.
				guard subscriptionState.isPaymentsSurfaceEnabled,
					  !subscriptionState.isSubscribed,
					  freeAccessEndsOn != nil else { return }
				if subscriptionState.products.isEmpty {
					await subscriptionState.loadProducts()
				}
				if let subscription = subscriptionState.products.first?.subscription {
					introOfferEligibility = await subscription.isEligibleForIntroOffer
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
			.sheet(isPresented: $showSignIn) {
				SignInSheet(authState: authState)
					// Settings is itself a sheet, so this is a *second* boundary and needs its own
					// re-injection (AGENTS.md §3). Without it the value falls back to `false` on Mac
					// and the sign-in button silently does nothing — the mock path has no configured
					// Clerk instance, so `SignInSheet` refuses to present rather than trapping.
					.environment(\.usesRealAuth, usesRealAuth)
			}
			// Subscribing from the Subscription row (AIA-0556). `isRootGate: false`, because this is
			// not a gate: dismissal is the sheet's own, so there are no account controls and no
			// findings escape hatch — both exist only where the paywall is a dead end. No
			// `authState` either: sign-out and account deletion live in the Clerk profile one row
			// below.
			//
			// `statesExpiredFreeAccess` defaults false, which is what this presentation wants:
			// someone opening this voluntarily has lost nothing, so the screen offers the
			// subscription rather than announcing an ending. Note that it is otherwise the *same*
			// screen as the wall now, benefit bullets and 3.1.2 copy included — AIA-0567 retired
			// acceptance criterion 8, so this sheet is no longer develop's paywall and the
			// free-access flag no longer makes it so.
			.sheet(isPresented: $showPaywall) {
				PaywallView(subscriptionState: subscriptionState, analytics: analytics)
					// A second sheet boundary, like the sign-in sheet above: custom environment
					// values do not reliably cross one on Mac (AGENTS.md §3), and the paywall reads
					// this to decide whether its own sign-in sheet may build Clerk's view.
					.environment(\.usesRealAuth, usesRealAuth)
			}
			// Signing out from inside Clerk's embedded profile dismisses the whole Settings sheet
			// (AIA-0536): sign-out means "I am done with account things", and popping back to the
			// Settings root would leave the user standing in a menu they did not ask for. Dismissal
			// lands them back in the app — which is what sign-out now means everywhere. Gated on a
			// non-empty path so an out-of-band session revocation while someone merely browses
			// Settings does not yank the sheet from under them; before the cut-over none of this
			// could happen, because sign-out tore the whole tree down.
			.onChange(of: authState.effectiveContext) { _, context in
				guard case .anonymous = context, !accountPath.isEmpty else { return }
				dismiss()
			}
		}
	}

	@ViewBuilder
	private var privacySection: some View {
		if analytics.isAnalyticsFeatureEnabled {
			Section(header: Text(L10n.Analytics.Settings.title), footer: Text(L10n.Analytics.Settings.footer)) {
				// Reads the derived value, not `settings.analyticsEnabled` — that field holds only
				// the anonymous bucket's answer, so an account-scoped user would be shown someone
				// else's choice while their own is in force (AIA-0536).
				Toggle(L10n.Analytics.Settings.toggle, isOn: Binding(
					get: { analytics.isAnalyticsEnabled },
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
			TextField(L10n.Settings.historyLimitPlaceholder, value: $settings.historySize, formatter: NumberFormatter.historyLimitFormatter)
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

	/// The app's own section — and, since AIA-0455, where the **subscription** lives.
	///
	/// It used to sit in the Account section, directly under the signed-in email address, which
	/// said as plainly as a layout can: *this account is subscribed*. That is not the model the app
	/// implements. Entitlement is scoped to the **Apple Account** that paid; the ML Browser account
	/// is identity, and the two need not belong to the same person — which is the whole of AIA-0525.
	/// Putting a subscription row under someone's email invited exactly the expectation the payment
	/// model then breaks.
	///
	/// Here it reads as what it is: something about the app you are paying for, next to what the app
	/// is. The free-access/trial footnote follows it for the same reason — it describes the
	/// subscription, never the account.
	private var mlBrowserSection: some View {
		Section(
			header: Text(L10n.Settings.Section.mlBrowser),
			footer: subscriptionFootnote.map { Text($0) }
		) {
			NavigationLink(destination: AppDescriptionView()
				.environment(\.dismissSheet, { dismiss() })) {
				Text(L10n.Settings.about)
			}
			.testability(Testability.NavigationLink.settingsAbout)

			// Hidden entirely when the remote brake is off, because then there is nothing for the
			// switch to control — persistence is already disabled and the stored log deleted. Note
			// this row lives here rather than in `privacySection`, which is itself wrapped in a
			// feature-flag check: a flag must never be able to hide a privacy control while the
			// behaviour it governs carries on.
			if settings.isDetailedLoggingFeatureEnabled {
				// The explanation is an inline `Text`, not the section footer: the footer slot already
				// carries the subscription footnote, which belongs to `subscriptionRow` below.
				Toggle(L10n.Settings.detailedLogging, isOn: $settings.detailedLoggingEnabled)
					.testability(Testability.Toggle.settingsDetailedLogging)
				Text(L10n.Settings.detailedLoggingExplanation)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			subscriptionRow

			replayOnboardingRow
			NavigationLink(destination: resetOptionsView) {
				Text(L10n.Settings.Reset.title)
			}
			.testability(Testability.NavigationLink.settingsReset)
		}
	}

	/// Subscription status and its entry points (AIA-0343), rendered in the ML Browser section.
	///
	/// Three states, unchanged by the move: subscribed pushes the status submenu (status, renewal,
	/// manage/cancel via Apple, restore); payments on with nothing owned opens the paywall — before
	/// AIA-0556 this was inert, which only became a problem once the free-access window let an
	/// unentitled user reach Settings at all; payments off shows the "Free Beta" row, where there is
	/// no gate to pass and no product to buy, so tapping could only lead nowhere.
	@ViewBuilder
	private var subscriptionRow: some View {
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
		} else if subscriptionState.isPaymentsSurfaceEnabled {
			Button {
				showPaywall = true
			} label: {
				HStack {
					Text(L10n.Auth.Account.subscription)
					Spacer()
					// "Not subscribed" also covers a lapse/refund before the gate refreshes.
					Text(L10n.Subscription.notSubscribed)
						.foregroundColor(.secondary)
				}
			}
			.testability(Testability.Button.settingsUpgrade)
		} else {
			HStack {
				Text(L10n.Auth.Account.subscription)
				Spacer()
				Text(L10n.Auth.Account.freeBeta)
					.foregroundColor(.secondary)
			}
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

	/// Builds a ZIP of all findings and hands it to the share sheet — WITHOUT deleting.
	///
	/// ``FindingsEscapeHatch`` owns the detached build and returns only AFTER the confirmation alert
	/// has finished dismissing, so a fast (e.g. single-finding) export cannot hit the
	/// "present while dismissing" no-op that would silently drop the share sheet (AIA-0402).
	private func exportFindingsBeforeRemoval() {
		isExportingFindings = true
		Task {
			defer { isExportingFindings = false }
			do {
				let url = try await FindingsEscapeHatch.makeShareableZip(from: findingRepository)
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

	/// The one line under the **ML Browser** block that says what the user is currently paying, or
	/// not (AIA-0556). `nil` renders no footer at all.
	///
	/// It followed the subscription row out of the Account section in AIA-0455 — it describes the
	/// subscription, and under an email address it read as a statement about that account.
	///
	/// Two free periods run through this app and they are easy to confuse, which is the whole reason
	/// this exists. The app-managed window is free *usage*: no subscription, no card, measured from
	/// install. Apple's introductory offer is a free *trial*: it belongs to a subscription, needs a
	/// payment method, and is measured from the purchase. The two never show together — the first is
	/// only reachable while unsubscribed, the second only once subscribed — so each line can state
	/// its own terms without hedging about the other.
	///
	/// The free-access line may also *mention* the trial ("an extra free trial of 2 weeks"), and
	/// that mention is a per-user claim about money: a returning Apple Account gets no second
	/// trial. So it follows the paywall's rule — stated only once the product's free-trial offer
	/// AND this user's eligibility are both confirmed; anything unresolved or negative falls back
	/// to the date-only sentence (AIA-0562/0576). Under-claiming is the safe direction: the
	/// paywall states the trial at the moment of subscribing, while nothing would ever correct an
	/// over-claim left standing here.
	private var subscriptionFootnote: String? {
		guard subscriptionState.isPaymentsSurfaceEnabled else { return nil }
		if subscriptionState.isSubscribed {
			guard subscriptionState.isInTrial, let ends = subscriptionState.currentExpirationDate else { return nil }
			return L10n.Settings.Subscription.trialFootnote(ends.formatted(date: .abbreviated, time: .omitted))
		}
		guard let freeAccessEndsOn else { return nil }
		let windowEnds = freeAccessEndsOn.formatted(date: .abbreviated, time: .omitted)
		if let product = subscriptionState.products.first,
		   product.hasFreeTrialIntroOffer,
		   introOfferEligibility == true,
		   let period = product.subscription?.introductoryOffer?.period.localizedDescription {
			return L10n.Settings.Subscription.freeAccessFootnote(windowEnds, period)
		}
		return L10n.Settings.Subscription.freeAccessFootnoteNoTrial(windowEnds)
	}

	/// Identity only, since AIA-0455 moved the subscription to the ML Browser section: sign in, who
	/// is signed in, and Clerk's profile. Nothing here is about money except the warning that
	/// deleting the account does not stop it.
	private var accountSection: some View {
		Section(header: Text(L10n.Auth.Account.title)) {
			// Signed out is a first-class state now (AIA-0536): the app is usable without an
			// account, so Settings offers sign-in instead of assuming it already happened.
			if case .anonymous = authState.effectiveContext {
				Button {
					showSignIn = true
				} label: {
					HStack {
						Text(L10n.Auth.SignIn.button)
						Spacer()
					}
				}
				.testability(Testability.Button.settingsSignIn)
			} else if case .suspended = authState.effectiveContext {
				// Signed in but unverifiable: the account must stay visible — vanishing reads as
				// broken (AIA-0536). Inert: Clerk cannot render the profile without a connection,
				// and offline its cache does not even yield the email, hence the generic label.
				HStack {
					Text(L10n.Auth.Account.title)
					Spacer()
					Text(L10n.Auth.Offline.title)
						.foregroundColor(.secondary)
						// On the leaf Text, not the HStack: a container's identifier surfaces
						// unreliably in the accessibility tree; a Text always does.
						.testability(Testability.Label.settingsAccountOffline)
				}
			} else if usesRealAuth, let email = Clerk.shared.user?.primaryEmailAddress?.emailAddress {
				HStack {
					Text(email)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
					Spacer()
				}
			}

			// Requires a *validated* account, not merely the real-auth path: Clerk's profile has
			// nothing to show for a signed-out user, and after the cut-over that is reachable here.
			if usesRealAuth, case .validated = authState.effectiveContext {
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

				// Deleting the account does not stop Apple billing (AIA-0528). Clerk owns the
				// delete confirmation inside `UserProfileView`, so its copy is not ours to amend —
				// and this is nonetheless the only delete path a *subscribed* user can walk, since
				// the paywall's own account controls are unreachable once entitled.
				//
				// Placed directly under the row it warns about rather than in the section footer:
				// that footer already carries the free-access/trial line, sits two pushes from
				// Clerk's delete button, and composing the two would mean a second variant for the
				// in-trial case. One key, adjacent to the control, says it once.
				//
				// Rendered only when subscribed — telling a non-subscriber their subscription
				// continues would be its own untruth — and `.secondary` is restated on the leaf
				// because the section-wide `.foregroundColor(.primary)` below would otherwise make
				// a note read as a statement.
				if subscriptionState.isSubscribed {
					Text(L10n.Auth.Account.deleteBillingNote)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.testability(Testability.Label.settingsDeleteBillingNote)
				}
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
