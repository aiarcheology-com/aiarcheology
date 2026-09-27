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
	/// The app's own delete-account screen, reached from the row this file injects into Clerk's
	/// profile one place under Sign out (AIA-0891). It rides `AccountRoute` rather than a type of
	/// its own because Clerk pushes a custom row's route onto the *host's* path, and a second route
	/// type would need a second `navigationDestination` for a stack that already has one.
	case deleteAccount
}

struct SettingsForm: View {
	/// The findings persistence repository (AIA-0303), used by the Reset section's "Remove
	/// Findings" action to delete all findings and to snapshot them for export. Passed by
	/// initializer (it is not an `ObservableObject`), from `DrawerContent`.
	let findingRepository: FindingRepository

	/// Auth, for the account section (AIA-0536). Sign-in is optional under the paywall-first gate
	/// order, so signed-out is a state Settings must render rather than one it can assume away.
	@ObservedObject var authState: AuthState

	/// Cloud sync, for the back-up switch in the account section (AIA-744). Settings is where a
	/// reversible data choice lives in this app -- it is where the analytics one already is.
	@ObservedObject var findingsSync: FindingsSyncCoordinator

	/// When the app-managed free window runs out, or `nil` when none is open (AIA-0556).
	///
	/// A plain `Date?` rather than the whole `FreeAccessState`: Settings only needs to state the
	/// date, and it cannot change while this sheet is up — the expiry is frozen at grant. Passed by
	/// initializer for the same reason `findingRepository` is.
	var freeAccessEndsOn: Date?

	/// Whole calendar days left in that window, read **when it is asked for** rather than captured
	/// here (AIA-0623). Forwarded to the paywall, which needs it at the instant Subscribe is tapped.
	///
	/// A closure where its neighbour above is a plain value, and the difference is not stylistic:
	/// the end date is frozen at grant, but the count is derived from the clock and the window can
	/// run out while this sheet is up. Passing a snapshot would let the paywall tell someone they
	/// still have days the gate has already stopped honouring.
	let freeAccessDaysRemaining: () -> Int?

	/// Clears both halves of the free-access anchor, for the DEBUG-only reset row (AIA-0826).
	///
	/// A closure rather than the state object, for the reason its two neighbours above are values:
	/// Settings needs one action, not a window it might start reading. Optional and defaulted so a
	/// preview — and a Release build, which has no row to call it from — passes nothing.
	let debugResetFreeAccess: (() throws -> Void)?

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
		findingsSync: FindingsSyncCoordinator,
		freeAccessEndsOn: Date? = nil,
		freeAccessDaysRemaining: @escaping () -> Int?,
		startAtManageAccount: Bool = false,
		debugResetFreeAccess: (() throws -> Void)? = nil
	) {
		self.findingRepository = findingRepository
		self._authState = ObservedObject(wrappedValue: authState)
		self._findingsSync = ObservedObject(wrappedValue: findingsSync)
		self.freeAccessEndsOn = freeAccessEndsOn
		self.freeAccessDaysRemaining = freeAccessDaysRemaining
		self.debugResetFreeAccess = debugResetFreeAccess
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
			settingsForm
				.navigationDestination(for: AccountRoute.self) { route in
					accountDestination(for: route)
				}
				.navigationBarTitle(L10n.Settings.title, displayMode: .inline)
				.toolbar { settingsToolbar }
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
				//
				// This is the one presentation that can be reached *during* an open window, so it is the
				// one that must hand the paywall the day count: subscribing here is what forfeits the
				// rest of the window (AIA-0623). The accessor, not a value — see the property.
				.sheet(isPresented: $showPaywall) {
					PaywallView(
						subscriptionState: subscriptionState,
						analytics: analytics,
						freeAccessDaysRemaining: freeAccessDaysRemaining
					)
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
	private var settingsForm: some View {
		Form {
			// Remotely-delivered informational messages targeted at the Settings surface, pinned
			// above the regular sections — only when the server actually delivered some.
			if !messageCenter.settingsMessages.isEmpty {
				messagesSection
			}
			annotationSection
			webContentSection
			mlBrowserSection
			accountSection
			backUpToggle
			debugSection
		}
	}

	@ViewBuilder
	private func accountDestination(for route: AccountRoute) -> some View {
		switch route {
		case .profile:
			// Embedded on the Settings stack (shares `accountPath`), so the profile's
			// own Manage-account / Security sub-screens resolve correctly.
			//
			// The injected Delete account row answers App Review 5.1.1(v) (AIA-0891).
			// Clerk's own delete affordance is buried in Security, four levels from
			// Settings, and 1.5.1 exposes no way to move, hide or relabel it — so this
			// adds a shallower second path to the same outcome instead of relocating the
			// first. `.after(.signOut)` is a supported placement, and because a custom
			// row pushes its `route` onto *this* stack, `AccountRoute.deleteAccount`
			// resolves in the same switch rather than needing `.userProfileDestination`.
			//
			// The row renders in Clerk's theme foreground, not destructive red:
			// `UserProfileRowView` hardcodes the label colour. Only the icon and title
			// are ours.
			//
			// The title is an already-resolved `L10n` string, which Clerk wraps in a
			// `LocalizedStringKey` and draws with `Text(_:bundle: nil)`. That is a main-
			// bundle lookup of the *translated* text as a key; it misses, and SwiftUI
			// falls back to rendering the key — the translation itself. Safe only because
			// this catalog's keys are dotted identifiers, so no locale's copy can collide
			// with one and get translated a second time.
			UserProfileView(isDismissible: false, navigationPath: $accountPath)
				.userProfileRows([
					UserProfileCustomRow(
						route: AccountRoute.deleteAccount,
						title: L10n.Auth.Account.Delete.action,
						icon: .system(name: "trash.fill"),
						placement: .after(.signOut)
					)
				])
				.environment(Clerk.shared)
				.environment(\.clerkTheme, .app)
				// A container, so the identifier stays off Clerk's own elements inside it.
				.accessibilityElement(children: .contain)
				.testability(Testability.View.settingsAccountProfile)
		case .subscription:
			SubscriptionStatusView(subscriptionState: subscriptionState)
		case .deleteAccount:
			DeleteAccountView(authState: authState, isPaymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled)
		}
	}

	@ToolbarContentBuilder
	private var settingsToolbar: some ToolbarContent {
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

	/// Two groups, for the reason set out on ``mlBrowserSection``: a row whose explanatory text sits
	/// underneath gets its **own** group, so the caption reads as belonging to that row rather than
	/// to whichever row happens to be last in a shared block. It matters more than usual here — the
	/// caption explains what is still recorded when the switch is off, and read as a note about
	/// "Delete cache" it would say something untrue.
	///
	/// Last in the section, because it is the one control here that nobody should need to touch: the
	/// feature works by default, and this exists for the person whose site it broke (AIA-0821).
	@ViewBuilder
	private var webContentSection: some View {
		Section(header: Text(L10n.Settings.Section.webContent)) {
			defaultPageRow
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

		Section(footer: Text(L10n.Settings.readMapPositionFromPagesFooter)) {
			// The user-reachable half of the map parser's kill switch. The developer launch argument
			// is unreachable to someone who has simply hit a site our injected script breaks, and
			// that person is the one who needs it.
			Toggle(L10n.Settings.readMapPositionFromPages, isOn: $settings.readMapPositionFromPages)
				.testability(Testability.Toggle.settingsReadMapPositionFromPages)
		}
	}

	private var defaultPageRow: some View {
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
			// Confirmed first (AIA-0331): `clean()` wipes every cookie and all website data, not
			// just the cache, and cannot be undone. Same item-based alert as Restore Defaults.
			Button(action: {
				alertItem = AlertItem(
					title: Text(L10n.Alert.DeleteCache.title),
					message: Text(L10n.Alert.DeleteCache.message),
					primaryButton: .destructive(Text(L10n.Common.delete)) {
						WebCacheCleaner.clean()
						cleanCacheButtonColor = .blue
					},
					secondaryButton: .cancel()
				)
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
	/// Two groups, following the platform convention (Settings → General → Keyboard → Hardware
	/// Keyboard is the reference): **a row whose explanatory text sits underneath gets its own
	/// group**, so the caption reads as belonging to that row rather than to whichever row happens to
	/// be last in a shared block.
	///
	/// That is why Subscription is separate. Its footnote ("Free until … no subscription, no payment
	/// method") used to be the *section's* footer, so it rendered under Reset and read as a note
	/// about resetting the app.
	///
	/// Only the first group carries the "ML Browser" header; the second is visually separate but
	/// belongs to it, exactly as the platform does it. The detailed-log switch lives on the About
	/// screen (`AppDescriptionView.debugSection`), with the version, build and support contact.
	@ViewBuilder
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

		// No Subscription section at all with payments off (AIA-0955): the app sells nothing, so a
		// row naming a plan — "Free Beta" until then — is subscription UI with nothing behind it.
		if subscriptionState.isPaymentsSurfaceEnabled {
			Section(footer: subscriptionFootnote.map { Text($0) }) {
				subscriptionRow
			}
		}
	}

	/// Subscription status and its entry points (AIA-0343), rendered in the ML Browser section.
	///
	/// Two states, rendered only with payments on: subscribed pushes the status submenu (status,
	/// renewal, manage/cancel via Apple, restore); nothing owned opens the paywall — before AIA-0556
	/// this was inert, which only became a problem once the free-access window let an unentitled
	/// user reach Settings at all. Payments off used to show a "Free Beta" row here; since AIA-0955
	/// the whole section is withheld instead.
	@ViewBuilder
	private var subscriptionRow: some View {
		if subscriptionState.isSubscribed {
			subscribedStatusRow
		} else {
			upgradeSubscriptionRow
		}
	}

	private var subscribedStatusRow: some View {
		NavigationLink(value: AccountRoute.subscription) {
			HStack {
				Text(L10n.Auth.Account.subscription)
				Spacer()
				Text(subscriptionState.isInTrial ? L10n.Subscription.trial : L10n.Paywall.active)
					.foregroundColor(.secondary)
			}
		}
		.testability(Testability.NavigationLink.settingsSubscription)
	}

	/// A plain tappable row rather than a `Button`, for the reason `replayOnboardingRow`
	/// records below (AIA-0333): inside a `List`, the button style renders the *label* gray
	/// and overrides `.foregroundStyle`, so this row alone read as disabled while every other
	/// row in Settings — including the two other branches of this very property — drew its
	/// label in the primary colour. `.buttonStyle(.plain)` fixes the colour but shrinks the
	/// tap target to the text, so the fix is the same one already proven in this file: a full
	/// -width `.contentShape` plus `.onTapGesture` (AIA-0623).
	///
	/// `.accessibilityElement(children: .combine)` is the one thing `replayOnboardingRow` does
	/// not need and this row does: that row holds a single `Text`, this one holds two, and
	/// without combining them there is no single element for the identifier and the button
	/// trait to land on — the row would surface as two labelled leaves and the UI tests would
	/// lose it. The trait is what keeps it announced as a control now that it is not a
	/// `Button`.
	private var upgradeSubscriptionRow: some View {
		HStack {
			Text(L10n.Auth.Account.subscription)
			Spacer()
			// "Not subscribed" also covers a lapse/refund before the gate refreshes.
			Text(L10n.Subscription.notSubscribed)
				.foregroundColor(.secondary)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			showPaywall = true
		}
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.testability(Testability.Button.settingsUpgrade)
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
			// Stage the demo page too (AIA-0757). First launch does this in
			// `AppState.initialize()`, but a replay never did — so the tour's opening step told the
			// user to load a site while whatever they happened to be browsing sat underneath, and
			// the demo models had nothing to detect on it. `pageToOpen` is the same latch a shared
			// link uses, so the load runs through the normal pipeline and fills the address bar.
			chromeState.pageToOpen = DemoDataManager.onboardingDemoPage
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
			// A new key, not an edit of the old one (AIA-0623). `freeAccessFootnote` said subscribing
			// starts "an extra free trial", and directly under a "Free until <date>" line that reads
			// as *additional to the days you have left* — which is the belief this ticket exists to
			// correct, one tap from the button that acts on it. Changing the English in place would
			// have left the other 16 locales holding a fluent translation of the old meaning, and no
			// gate can see that (AGENTS §8): the ratchet counts presence and `verify` checks shape.
			return L10n.Settings.Subscription.freeAccessFootnoteWithTrial(windowEnds, period)
		}
		return L10n.Settings.Subscription.freeAccessFootnoteNoTrial(windowEnds)
	}

	/// Identity only, since AIA-0455 moved the subscription to the ML Browser section: sign in, who
	/// is signed in, and Clerk's profile. Nothing here is about money except the warning that
	/// deleting the account does not stop it.
	/// The back-up switch (AIA-744).
	///
	/// Only while signed in and only when the build has a Worker: offering to turn off something
	/// that cannot happen would be a promise about a feature the user does not have.
	@ViewBuilder
	private var backUpToggle: some View {
		if let account = authState.accountIdentifier, findingsSync.isCloudConfigured {
			Section(footer: Text(L10n.Findings.Sync.Backup.toggleFooter)) {
				Toggle(
					L10n.Findings.Sync.Backup.toggle,
					isOn: Binding(
						get: { findingsSync.isBackUpEnabled },
						// The account travels with the decision, and the coordinator refuses it if
						// the provider has moved on -- the same fence the back-up button uses, for
						// the same reason: `AuthState` lags during an account switch.
						set: { findingsSync.setBackUpEnabled($0, expectedAccount: account) }
					)
				)
				.testability(Testability.Toggle.findingsBackUp)
			}
		}
	}

	private var accountSection: some View {
		Section(header: Text(L10n.Auth.Account.title)) {
			Group {
				accountIdentityRows
				manageAccountRows
			}
			// On the **rows**, not on the `Section`. The rows need it: the signed-out row is a
			// `Button`, and inside a `List` SwiftUI draws a button's label in the tint colour, which
			// is the same mechanism that made the Subscription row look disabled (AIA-0623).
			//
			// A modifier on the `Section` reaches its header too, and drew "Account" in `.primary`
			// while every other header in this Form — Annotation, Web Content, ML Browser — kept the
			// system's own header colour, so the one section with a colour was the one that looked
			// wrong. `Group` applies the modifier to each child individually, so the rows are
			// unchanged and the header is left to inherit. Deliberately inheriting rather than
			// restating a grey on the header: a literal would be a second opinion about a colour the
			// system owns, and would drift from the other five headers the first time it changed.
			.foregroundColor(.primary)
		}
	}

	@ViewBuilder
	private var accountIdentityRows: some View {
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
	}

	@ViewBuilder
	private var manageAccountRows: some View {
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

			// Deleting the account does not stop Apple billing (AIA-0528). This is the only
			// delete path a *subscribed* user can walk, since the paywall's own account
			// controls are unreachable once entitled.
			//
			// It used to be the only place the app could say so at all, because Clerk owned
			// the sole delete confirmation and its copy is not ours to amend. AIA-0891 added
			// one we do own — `DeleteAccountView`, reached from the row this section pushes
			// to — and its confirmation carries the same warning. This note is kept rather
			// than retired: Clerk's own delete under Security is still reachable, still
			// unamendable, and a subscriber who walks that path would otherwise be told
			// nothing about billing at all.
			//
			// Placed directly under the row it warns about rather than in the section footer:
			// that footer already carries the free-access/trial line, sits two pushes from
			// Clerk's delete button, and composing the two would mean a second variant for the
			// in-trial case. One key, adjacent to the control, says it once.
			//
			// Rendered only when subscribed — telling a non-subscriber their subscription
			// continues would be its own untruth — and `.secondary` is restated on the leaf
			// because the rows' `.foregroundColor(.primary)` below would otherwise make a note
			// read as a statement.
			if subscriptionState.isSubscribed {
				Text(L10n.Auth.Account.deleteBillingNote)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.testability(Testability.Label.settingsDeleteBillingNote)
			}
		}
	}

	@ViewBuilder
	private var debugSection: some View {
		if AppEnvironment.isAppStoreDistribution.not {
			Section(header: Text(L10n.Settings.Section.debug)) {
				NavigationLink(destination: SentryStatsView()) {
					Text(L10n.Settings.Sentry.title)
				}
				#if DEBUG
				resetFreeAccessRow
				#endif
			}
		}
	}

	#if DEBUG
	/// Clears the free-access anchor so the next launch is a first install (AIA-0826).
	///
	/// `#if DEBUG` **on top of** the section's own gate, which is not redundant: that gate is
	/// `isAppStoreDistribution.not`, which is true under TestFlight. A reset row in a tester's
	/// hands is an unlimited free-window farm — exactly what the durable anchor exists to prevent
	/// (#557) — so the guarantee has to be that the code is not in the binary at all.
	///
	/// `verbatim:` because this never ships and must never be translated: a developer tool, in the
	/// vocabulary of the code it resets. It is also the only way to keep it out of the string
	/// catalog, which `SWIFT_EMIT_LOC_STRINGS` would otherwise extract a literal into.
	@ViewBuilder
	private var resetFreeAccessRow: some View {
		if let debugResetFreeAccess {
			Button(role: .destructive) {
				alertItem = AlertItem(
					title: Text(verbatim: "Reset free access?"),
					message: Text(verbatim: """
						Clears the free-access anchor from this app's UserDefaults and from the \
						keychain, where deleting the app does not reach. The next launch then \
						reconciles as a first install.

						It grants a new 14-day window and shows the day-0 Welcome only if nothing \
						else refuses: an entitlement you already hold, payments off, or the \
						free-access flag off.
						"""),
					primaryButton: .destructive(Text(verbatim: "Reset")) {
						performDebugFreeAccessReset(debugResetFreeAccess)
					},
					secondaryButton: .cancel()
				)
			} label: {
				Text(verbatim: "Reset free access")
			}
		}
	}

	/// Runs the reset and reports what actually happened.
	///
	/// The success alert asks for a relaunch rather than claiming the app is now in a first-run
	/// state, because it is not: `FreeAccessState.availability` settled at launch and deliberately
	/// never settles twice, so the gate above this sheet is still holding the answer the old anchor
	/// produced. The stores are what changed, and they are read on the next launch.
	private func performDebugFreeAccessReset(_ reset: () throws -> Void) {
		do {
			try reset()
			alertItem = AlertItem(
				title: Text(verbatim: "Free access reset"),
				message: Text(verbatim: """
					Both stores are empty, and nothing in this session will write them back. \
					The access decision made at launch stands until you quit and relaunch.
					"""),
				dismissButton: .default(Text(L10n.Common.ok))
			)
		} catch {
			// Named rather than swallowed: a keychain delete that failed left the anchor in place,
			// and the durable copy is deleted first precisely so this leaves both stores untouched.
			alertItem = AlertItem(
				title: Text(L10n.Alert.Error.title),
				message: Text(verbatim: "Nothing was reset: \(Self.debugResetFailureReason(error))."),
				dismissButton: .default(Text(L10n.Common.ok))
			)
		}
	}

	/// Why a reset failed, in terms the person reading it can act on.
	///
	/// Not `localizedDescription`: `FreeAccessAnchorError` is a plain `Error`, so that property
	/// synthesises "The operation couldn't be completed. (… error 0.)" — which names neither the
	/// failure nor the one number that identifies it. The `OSStatus` is the whole diagnosis here;
	/// `-34018` (`errSecMissingEntitlement`) in particular says the build cannot reach the keychain
	/// at all, which is a signing problem and not a reset that merely went wrong.
	private static func debugResetFailureReason(_ error: Error) -> String {
		switch error {
		case FreeAccessAnchorError.keychain(let status):
			return "keychain error \(status)"
		case FreeAccessAnchorError.malformedRecord:
			return "the stored anchor could not be decoded"
		default:
			return String(describing: error)
		}
	}
	#endif

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
