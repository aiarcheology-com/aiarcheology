//
//  DrawerContent.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import CoreData
import ClerkKit
import StoreKit

private enum SettingsPresentation: Hashable, Identifiable {
    case settings
    case manageAccount

    var id: Self { self }

    var startsAtManageAccount: Bool {
        self == .manageAccount
    }
}

/// The content displayed inside the drawer for MLBrowser.
///
/// This view displays the list of ML configurations.
/// Detail view and import are presented as sheets for consistent UX
/// and to provide adequate screen space on all devices.
struct DrawerContent: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(DrawerManager.self) private var drawer
    @Environment(TourState.self) private var tour
    @Environment(\.usesRealAuth) private var usesRealAuth
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var chromeState: AppChromeState
	@EnvironmentObject private var appState: AppState
    /// Not used by DrawerContent itself — forwarded into the Settings sheet, which needs it
    /// (env objects don't cross a `.sheet` boundary on Mac/Designed-for-iPad). AIA-0391.
    @EnvironmentObject private var detectionState: DetectionSessionState
    @EnvironmentObject private var deep: DeepState
    @EnvironmentObject private var downloader: Downloader
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var subscriptionState: SubscriptionState
    /// Observed rather than reached through `appState` (AIA-0536): a nested ObservableObject does
    /// not republish through its parent, so the sign-in row below would go stale the moment the
    /// session changed. Before the cut-over a sign-out unmounted this whole tree.
    @EnvironmentObject private var authState: AuthState
	@EnvironmentObject private var analytics: AnalyticsState

    @FetchRequest(
        entity: DeepConfiguration.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \DeepConfiguration.creationDate_, ascending: false)
        ],
        predicate: NSPredicate(
            format: "%K == %@",
            #keyPath(DeepConfiguration.lifeCycleString),
            CoreDataManageableState.ready.rawValue
        )
    ) private var configurations: FetchedResults<DeepConfiguration>
    
    /// Controls the model import sheet
    @State private var showImport = false

    /// Controls the findings inventory sheet
    @State private var showFindings = false

    /// Controls the settings sheet (presented here, not at ContentView level,
    /// so the drawer stays open behind it — same behavior as Findings)
    @State private var settingsPresentation: SettingsPresentation?
    /// Contextual sign-in from the drawer (AIA-0536).
    @State private var showSignIn = false

    /// The configuration ID to show in detail sheet
    @State private var selectedConfigurationId: UUID?

    /// Set by the import sheet on success; consumed when the import sheet finishes dismissing to
    /// auto-open the new model's settings for type confirmation (AIA-0402).
    @State private var importedForReviewId: UUID?

    /// The configuration whose settings are currently shown as a post-import type review. Drives
    /// the confirmation banner / red-Disabled treatment in `ConfigurationForm` (AIA-0402).
    @State private var typeReviewConfigId: UUID?

    /// Guards the one-shot UI-test auto-review hook so it fires at most once per launch (AIA-0402).
    @State private var didAutoReviewForUITests = false

    var body: some View {
        NavigationStack {
            configurationList
                // No `.navigationTitle`: the toolbar's Add Model button now carries a visible title,
                // and a centred "Models" between it and the close cross crowds the drawer's narrow
                // bar (AIA-0757 D2). The list names itself instead — see `configurationList`.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                // Pinned to the drawer's bottom edge, outside the scrolling list (AIA-0536): the
                // account slot is chrome, not content — it should not scroll away under a long
                // model list, and "sign in / who am I" living in the bottom corner of the slide
                // menu is the standard place users look for it.
                .safeAreaInset(edge: .bottom) { accountFooter }
        }
        .sheet(isPresented: $showImport, onDismiss: presentTypeReviewIfNeeded) {
            ModelImportView(
                onImported: { id, needsReview in
                    appState.reviewPrompt.recordPositiveMoment(.modelImported)
                    if needsReview { importedForReviewId = id }
                },
                catalogProviders: appState.catalogProviders,
				catalogSearchManager: appState.catalogSearchManager,
				nativeConversionSourceCleanupService: appState.nativeConversionSourceCleanupService
            )
                .environmentObject(deep)
                .environmentObject(downloader)
                // Environment objects do not reliably cross `.sheet` boundaries on Mac
                // (Designed for iPad) — re-inject, per AGENTS.md §3 (AIA-0350).
                .environmentObject(appState.featureFlags)
				.environmentObject(analytics)
        }
        .sheet(item: $selectedConfigurationId, onDismiss: {
            // Only the post-import type review continues the import flow (AIA-0117); an ordinary
            // configuration sheet closing must not be able to spend a moment, least of all one
            // another window recorded.
            let wasTypeReview = typeReviewConfigId != nil
            typeReviewConfigId = nil
            if wasTypeReview { requestReviewIfEarned() }
        }) { configId in
            if let config = deep.selectConfiguration(configId) {
                ConfigurationForm(pendingTypeReview: configId == typeReviewConfigId)
					// ConfigurationForm previews app-provided sounds through AppState; sheets need
					// explicit reinjection on Mac (Designed for iPad).
					.environmentObject(appState)
                    .environmentObject(deep)
                    .environmentObject(config)
            }
        }
        .sheet(isPresented: $showFindings) {
            FindingsListView(
                findingRepository: appState.findingRepository,
                findingsSync: appState.findingsSync,
                authState: authState
            ) { url in
                // Open the captured page: tear down this sheet and the drawer,
                // then hand the URL to the web screen via chromeState.pageToOpen.
                showFindings = false
                drawer.close()
                chromeState.pageToOpen = url
            }
            // Re-inject the context: on Mac (Designed for iPad) SwiftUI does not
            // reliably carry \.managedObjectContext across the sheet boundary, so
            // the fetch/distinctLabels would hit the empty default context and crash.
            .environment(\.managedObjectContext, moc)
            // Same reason (AIA-0650): the share composer two sheets down reads
            // `isFindingShareLinkEnabled` live, and this is where the chain starts.
            .environmentObject(appState.featureFlags)
            // Same reason again (AIA-740): the back-up button raises its own `SignInSheet`, which
            // branches on this to decide whether to build Clerk's `AuthView` at all.
            .environment(\.usesRealAuth, usesRealAuth)
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet(authState: authState)
                // Re-inject: custom env values don't reliably cross a sheet boundary on Mac
                // (Designed for iPad) — AGENTS.md §3. `SignInSheet` branches on this to decide
                // whether to build Clerk's `AuthView` at all, and the mock path has no configured
                // Clerk instance, so losing it here would trap rather than degrade.
                .environment(\.usesRealAuth, usesRealAuth)
        }
        .sheet(item: $settingsPresentation) { presentation in
            // FindingRepository is a plain (non-ObservableObject) type, so it is passed by
            // initializer rather than injected as an environment object (AIA-0303), the same way
            // WebScreen hands it to SaveFindingSheet.
            SettingsForm(
                findingRepository: appState.findingRepository,
                authState: authState,
                findingsSync: appState.findingsSync,
                // The free window's end date, so the account section can say plainly what the user
                // is on — free usage, not a trial (AIA-0556). A value rather than the state object:
                // it is frozen at grant and cannot change while this sheet is up.
                freeAccessEndsOn: appState.freeAccess.windowEndsOn,
                // The days left, as an accessor rather than a value (AIA-0623): the paywall reached
                // from Settings reads it at the moment Subscribe is tapped, and unlike the end date
                // above this number moves — the window can run out while the sheet is open.
                freeAccessDaysRemaining: { appState.freeAccess.windowDaysRemaining },
                startAtManageAccount: presentation.startsAtManageAccount
            )
                .environmentObject(settings)
                .environmentObject(chromeState)
                .environmentObject(detectionState)
                .environmentObject(subscriptionState)
				.environmentObject(analytics)
                // AIA-0115: AppDescriptionView (pushed inside this sheet) reads remote messages,
                // and environment objects do not reliably cross a `.sheet` boundary on Mac
                // (Designed for iPad) — re-inject or its @EnvironmentObject traps. See AGENTS §3.
                //
                // `featureFlags` was injected here for the same reason until AIA-0455: its only
                // reader in this subtree was SubscriptionStatusView's refund row. Nothing under
                // Settings reads the flags now, so re-add this if that ever changes.
                .environmentObject(appState.messageCenter)
                .environment(drawer)
                .environment(tour)
                // Re-inject: custom env values don't reliably cross the sheet boundary on
                // Mac (Designed for iPad), same as \.managedObjectContext above (AIA-0385).
                .environment(\.usesRealAuth, usesRealAuth)
        }
    }
    
    /// After the import sheet finishes dismissing, open the newly imported model's settings so the
    /// user confirms its type. Presenting the settings sheet here (not while the import sheet is
    /// still up) avoids the "present while dismissing" no-op (AIA-0402).
    private func presentTypeReviewIfNeeded() {
        guard let id = importedForReviewId else {
            // AIA-0117: no type review follows, so the import flow ends here. When one does
            // follow, the ask waits for that sheet's dismissal instead.
            requestReviewIfEarned()
            return
        }
        importedForReviewId = nil
        typeReviewConfigId = id
        selectedConfigurationId = id
    }

    /// Asks for an App Store review iff an import moment is pending and the policy allows it
    /// (AIA-0117). Only the two dismissals that end an import flow call this.
    private func requestReviewIfEarned() {
        if appState.reviewPrompt.consumePendingRequest(.modelImported, isTourActive: tour.isActive) {
            requestReview()
        }
    }

    // MARK: - Configuration List

    private var configurationList: some View {
        List {
            if configurations.isEmpty {
                emptyStateView
            } else {
                configurationsSection
            }

            // Intentionally outside the configurations branch: Findings and
            // Settings must be reachable even when no models are imported yet.
            findingsSection
            settingsSection
        }
        .listStyle(.insetGrouped)
        // Names the drawer for VoiceOver now that the navigation title is gone (AIA-0757 D2).
        // `configurationsSection` carries its own header, but the empty branch has none, so without
        // this the first thing a model-less drawer announces is the close button.
        //
        // `children: .contain` first, deliberately: an accessibility modifier on a view that is not
        // itself an element propagates down to every leaf, which would relabel all four drawer
        // buttons — including the one three UI tests resolve as `app.buttons["Add Model"]`. Marking
        // the List a container makes the label land on the container and stop there.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Models.title)
        // The drawer is a fixed-width panel anchored at the leading edge. In landscape the
        // List would otherwise inset its content by the device's leading safe area (the
        // Dynamic Island side), wasting a gutter inside the panel. The panel is the safe
        // container here, so let the List span its full width in both orientations.
        .ignoresSafeArea(.container, edges: .horizontal)
        // The tour spotlights the whole drawer for the in-drawer steps (a precise model-row cutout
        // isn't reachable — anchors inside a List cell don't propagate to the overlay).
        .tourTarget(.demoModels)
        // The enable step is overlay-driven (the toggle can't be tapped through the spotlight):
        // register the action that enables a demo model when the cutout is tapped (AIA-0333).
        .onAppear {
            let context = moc
            tour.bindEnableModel { enableFirstReadyDemoModel(in: context) }
            presentFindingsIfRequested()
        }
        // A shared link that turned out to be the recipient's own finding asks for this sheet
        // (AIA-0650). It arrives as a latch on chrome state rather than a call because this view is
        // unmounted while the drawer is closed — which is precisely when the request is made, so
        // `onAppear` above is the branch that normally fires. This one covers the drawer already
        // being open.
        .onChange(of: chromeState.presentsFindings) { _, _ in
            presentFindingsIfRequested()
        }
        // UI-test-only hook (AIA-0402): once the first model has seeded, force it to look unparsed
        // (the seeded demos are parser-decided → read-only) and auto-open its settings in type-review
        // mode, so tests can exercise the editable picker + confirmation footnotes without the
        // un-scriptable file import. `shouldReviewFirstModelType` is false in every shipping build.
        .onChange(of: configurations.first?.entityId, initial: true) { _, firstId in
            guard UITestLaunchConfiguration.shouldReviewFirstModelType,
                  !didAutoReviewForUITests, let firstId,
                  let config = deep.selectConfiguration(firstId) else { return }
            didAutoReviewForUITests = true
            config.modelTypeParsed = false
            typeReviewConfigId = firstId
            selectedConfigurationId = firstId
        }
    }

    /// Consumes the `presentsFindings` latch (AIA-0650). Reset before presenting so the request is
    /// spent exactly once — a latch left set would re-open the sheet every time the drawer is opened.
    private func presentFindingsIfRequested() {
        guard chromeState.presentsFindings else { return }
        chromeState.presentsFindings = false
        showFindings = true
    }

    /// The label colour for the drawer's own rows — Findings, Settings and the account footer.
    ///
    /// Stated explicitly because the app's `AccentColor` is a **deliberate neutral grey** (0.700 in
    /// light appearance; see `PaywallView.interactiveTint`), and a `Button` label that sets no colour
    /// of its own inherits it. That is why these three read as disabled while being perfectly live —
    /// AIA-0757 D1. The Add Model and `✕` buttons above escaped it only by setting `.tint(.blue)`.
    ///
    /// Applied with `.tint`, **not** `.foregroundStyle`. `SettingsView.replayOnboardingRow` records
    /// that the list-button style renders its label gray *and overrides* `.foregroundStyle`, which is
    /// why that row had to stop being a `Button` at all. These three cannot take that escape — three
    /// UI tests resolve them as `app.buttons[…]` — so they use the mechanism the toolbar's two
    /// buttons already prove works here: the tint the button style itself reads.
    ///
    /// Mirrors `.disabled(tour.isActive)` rather than reading `\.isEnabled`: the disable is applied
    /// *below* this view, so the environment here would still say enabled — and an unconditional
    /// `.primary` would leave the rows looking live during the tour, when they deliberately do nothing.
    private var drawerRowLabelColor: Color {
        tour.isActive ? .secondary : .primary
    }

    private var findingsSection: some View {
        Section {
            Button {
                showFindings = true
            } label: {
                Label(L10n.Findings.title, systemImage: "archivebox")
            }
            .tint(drawerRowLabelColor)
            .testability(Testability.Button.drawerFindings)
            // During the tour the whole drawer is the spotlight; keep only the model toggles
            // interactive so the user can't wander off into Findings (AIA-0333).
            .disabled(tour.isActive)
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                settingsPresentation = .settings
            } label: {
                Label(L10n.Settings.title, systemImage: "gearshape")
            }
            .tint(drawerRowLabelColor)
            .testability(Testability.Button.drawerSettings)
            .disabled(tour.isActive)
        }
    }

    /// The drawer's bottom slot: always "who am I" (AIA-0536). Sign In while signed out; the
    /// signed-in account otherwise, deep-linking to Settings → Manage Account. Pinned via
    /// `safeAreaInset` so it cannot scroll away, and absent entirely for `.indeterminate` /
    /// `.suspended` — sign-in would fail offline, and the account row would promise a profile
    /// Clerk cannot show.
    @ViewBuilder
    private var accountFooter: some View {
        switch authState.effectiveContext {
        case .anonymous:
            accountFooterButton(title: L10n.Auth.SignIn.button, systemImage: "person.crop.circle") {
                showSignIn = true
            }
            .testability(Testability.Button.drawerSignIn)
        case .validated:
            // The email is read at render time, not observed — safe because the footer re-renders
            // on every context change (authState IS observed), and the email cannot change without
            // one. Mock auth has no Clerk instance to read, so it falls back to the generic label.
            accountFooterButton(title: signedInLabel, systemImage: "person.crop.circle.fill") {
                // Deep-link only on the real-auth path: the profile destination reads
                // `Clerk.shared`, which traps when Clerk was never configured, so a mock-auth tap
                // opens plain Settings instead of pushing a screen that would crash.
                settingsPresentation = usesRealAuth ? .manageAccount : .settings
            }
            .testability(Testability.Button.drawerAccount)
        case .suspended:
            // Signed in, unverifiable — the account still EXISTS and the slot must say so
            // (an empty slot reads as broken, which is how this state was found). Disabled:
            // sign-in would fail with no network, and Clerk cannot render the profile.
            accountFooterCard {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.Auth.Account.title)
                        Text(L10n.Auth.Offline.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                }
                .foregroundStyle(.secondary)
            }
            .testability(Testability.Label.drawerAccountOffline)
        case .indeterminate:
            // Transient (auth is still resolving) — a row that flickers in and out for a second
            // at launch is worse than a brief absence.
            EmptyView()
        }
    }

    /// One footer card, styled to match the drawer's inset-grouped rows.
    private func accountFooterButton(
        title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            accountFooterLabel {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .tint(drawerRowLabelColor)
        .disabled(tour.isActive)
    }

    /// The non-interactive variant, for states with something to show but nothing to do.
    private func accountFooterCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        accountFooterLabel(content: content)
    }

    /// The footer's card, matched to the drawer's own `.insetGrouped` rows (AIA-0620).
    ///
    /// This slot is pinned with `safeAreaInset`, so it cannot be a `List` section — it is drawn by
    /// hand, and the hand-drawn metrics had drifted from the real rows above it: a 12pt radius
    /// against UIKit's inset-grouped 10, and 14pt of vertical padding against a standard row's 11.
    /// Small numbers, but they sit directly beneath Findings and Settings, where "nearly the same"
    /// reads as a mistake rather than a distinct element.
    ///
    /// Kept as literals rather than derived: UIKit exposes no API for these, so a comment naming
    /// what they mirror is the honest way to hold them. If the rows above ever change style, this
    /// is the place that has to follow.
    private func accountFooterLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .padding(.horizontal, 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    /// The signed-in row's label: the account email when Clerk can provide one, else "Account".
    private var signedInLabel: String {
        if usesRealAuth, let email = Clerk.shared.user?.primaryEmailAddress?.emailAddress {
            return email
        }
        return L10n.Auth.Account.title
    }
    
    private var emptyStateView: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text(L10n.Models.Empty.title)
                    .font(.headline)

                Text(L10n.Models.Empty.messageAddModel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
    
    private var configurationsSection: some View {
        // Resolved once for the whole section: every row asks whether *it* is the pulsed one.
        let pulsedModelID = tourPulsedModelObjectID
        return Section(L10n.Models.Available.title) {
            // Use objectID for identity - it's always valid even for deleted objects.
            // Using entityId crashes when Core Data nullifies it during deletion.
            ForEach(configurations, id: \.objectID) { configuration in
                // Capture entityId early, before any async operations could invalidate it
                let entityId = configuration.entityId
                ConfigurationRow(
                    configuration: configuration,
                    tour: tour,
                    pulsesToggle: configuration.objectID == pulsedModelID,
                    onTap: {
                        selectedConfigurationId = entityId
                    },
                    onDelete: {
						deep.deleteConfiguration(entityId)
                    }
                )
            }
        }
    }

    /// The single model row whose switch pulses during the tour's "switch a model on" step
    /// (AIA-0757 A4), or `nil` on every other step. `ConfigurationRow` is built for *every*
    /// configuration — imported and invalid ones included — so a plain "is this the enable step?"
    /// test would pulse every switch in the list while only one of them is the model the step
    /// actually turns on. Asks `demoModelTheTourWillEnable(among:)`, the same function that
    /// performs the flip, so the two can't disagree. `configurations` is already the ready-only
    /// fetch, which that predicate re-checks anyway.
    private var tourPulsedModelObjectID: NSManagedObjectID? {
        guard tour.isActive, tour.currentStep?.id == .enableModelToggle else { return nil }
        return demoModelTheTourWillEnable(among: configurations)?.objectID
    }

    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // A titled button rather than the bare `plus.circle.fill` it replaced (AIA-0757 D2): a
            // glyph alone left the drawer's only creative action unnamed on screen. The title also
            // *is* the accessibility label now, which is why the explicit one is gone — and what
            // keeps `app.buttons["Add Model"]` resolving in FeatureFlagUITests.
            Button {
                showImport = true
            } label: {
                Text(L10n.Models.add)
            }
            .tint(.blue)
            // Keep only the model toggles interactive during the tour (AIA-0333).
            .disabled(tour.isActive)
        }

        ToolbarItem(placement: .topBarTrailing) {
            // A plain cross, balancing the leading Add Model button across the bar.
            Button {
                drawer.close()
            } label: {
                Image(systemName: "xmark")
            }
            .tint(.blue)
            .accessibilityLabel(L10n.Common.dismiss)
            .disabled(tour.isActive)
        }
    }
}

// MARK: - Tour enable action

/// The models the tour's enable step is allowed to touch: seeded demos that finished downloading.
private func readyDemoModels<S: Sequence>(among configurations: S) -> [DeepConfiguration]
where S.Element == DeepConfiguration {
    configurations.filter { $0.demo && $0.lifeCycleString == CoreDataManageableState.ready.rawValue }
}

/// The one model `enableFirstReadyDemoModel(in:)` will flip: the newest ready demo still switched
/// off. Newest-first matches the list's sort order, so it is the top eligible row.
///
/// Factored out rather than restated because two callers need the *same* answer (AIA-0757 A4):
/// this function performs the flip, and the drawer list pulses the switch it will flip. A second
/// copy of the predicate could drift and leave the app pulsing one model while tapping the
/// spotlight turns on another.
private func demoModelTheTourWillEnable<S: Sequence>(among configurations: S) -> DeepConfiguration?
where S.Element == DeepConfiguration {
    readyDemoModels(among: configurations)
        .filter { $0.enabled == false }
        .max(by: { ($0.creationDate_ ?? .distantPast) < ($1.creationDate_ ?? .distantPast) })
}

/// Ensures a demo model is enabled for the onboarding tour's overlay-driven enable step
/// (AIA-0333). Returns `true` if a demo model is enabled afterwards — including the **Replay**
/// case where one is already on (so the step isn't stuck), and only `false` when there are no
/// ready demo models at all or the save fails.
private func enableFirstReadyDemoModel(in context: NSManagedObjectContext) -> Bool {
    let all = DeepConfiguration.selectAll(in: context)
    guard readyDemoModels(among: all).isEmpty == false else { return false }

    // If they're all already enabled (Replay), the step's goal already holds — proceed.
    guard let target = demoModelTheTourWillEnable(among: all) else { return true }
    target.enabled = true
    do {
        try DeepConfiguration.save(in: context)
        return true
    } catch {
        LoggingPolicy.error("Failed to enable demo model during onboarding tour", error: error, logger: .configuration)
        context.refresh(target, mergeChanges: false)
        return false
    }
}

// MARK: - Configuration Row

/// A single row in the configurations list.
/// Uses `.buttonStyle(.borderless)` to isolate gesture handling, enabling
/// swipe actions to coexist with Toggle on all platforms.
private struct ConfigurationRow: View {
    @ObservedObject var configuration: DeepConfiguration
    /// The tour engine, poked when a demo model is enabled during the enable-model step (AIA-0333).
    var tour: TourState?
    /// True for the one row the tour's enable step will switch on — see
    /// `DrawerContent.tourPulsedModelObjectID`. Passed down rather than derived here: this row can
    /// only see itself, and the step targets exactly one model out of the whole list.
    var pulsesToggle: Bool = false
    let onTap: () -> Void
    let onDelete: () -> Void

    /// Where this model came from (AIA-0459). Read from disk in `.task` rather than in `body`: the
    /// answer lives in the configuration's conversion report, and a file read per render would run
    /// on every list redraw.
    @State private var provenance: ModelProvenance?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Same normalization the label bubble uses (AIA-0472): blank-after-trim counts as
                // nameless, so the drawer and the bubble can never disagree about a model's name.
                Text(DeepConfiguration.displayName(from: configuration.modelDescription))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .testability(Testability.Label.sideMenuCellDescription)
                
                // Author and provenance share one caption line: "AI Archeology · Converted from ONNX".
                // Either half may be absent — the provenance only after the disk read completes.
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Model type at a glance (Detect / Classify / Disabled) — AIA-0402. Left untagged so
                // its accessibility label stays the displayed type (a `.testability` tag would
                // replace the label with the identifier under UI tests).
                Text(configuration.modelType.localizedName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            
            Toggle("", isOn: Binding(
                get: { configuration.enabled },
                set: { newValue in
                    let wasEnabled = configuration.enabled
                    configuration.enabled = newValue
                    if let context = configuration.managedObjectContext {
                        do {
                            try DeepConfiguration.save(in: context)
                            // Tour hook (AIA-0333): only after the enable actually persisted, if a
                            // model was enabled via a real toggle tap during the enable step, reveal
                            // the bubble's Next. (Normally overlay-driven — tapping the spotlight
                            // enables a model — so this is the pass-through path; a no-op otherwise.)
                            if wasEnabled == false, newValue {
                                tour?.userEnabledModel()
                            }
                        } catch {
                            LoggingPolicy.error("Failed to save configuration toggle", error: error, logger: .configuration)
                            // Reload from the store so the toggle reflects the persisted
                            // state instead of silently diverging from it.
                            context.refresh(configuration, mergeChanges: false)
                        }
                    }
                }
            ))
            .tint(configuration.annotationColor)
            .labelsHidden()
            .testability(Testability.Toggle.sideMenuCellEnabled)
            // A Disabled (undetermined-type) model can't run — block enabling it until the user
            // picks a type in the config form (AIA-0402).
            .disabled(configuration.modelType == .invalid)
            // AIA-0757 A4: on the "switch a model on" tour step, ring this switch so it's obvious
            // it is meant to be turned on. Non-hit-testing decoration (see `TourPulse`), so the
            // switch underneath stays tappable — the tour's pass-through enable path depends on it.
            .overlay {
                if pulsesToggle {
                    TourPulse(cornerRadius: 20)
                        // Negative padding grows the ring outward, clear of the switch itself.
                        .padding(-5)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .buttonStyle(.borderless)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label(L10n.Common.delete, systemImage: "trash")
            }
            .testability(Testability.Button.sideMenuDeleteConfiguration)
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(L10n.Common.delete, systemImage: "trash")
            }
        }
        // Keyed by objectID, NOT entityId: the id is re-evaluated while a swipe-deleted row leaves,
        // and Core Data has nullified the object by then — bridging its non-optional UUID traps
        // (the exact hazard the ForEach above documents; crashed testDrawer_deleteModel_removesCell).
        .task(id: configuration.objectID) { loadProvenance() }
    }

    /// "AI Archeology · Converted from ONNX" — either half alone when the other is missing.
    private var subtitle: String? {
        let parts: [String] = [configuration.author, provenanceText].filter(\.isNotBlank).compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var provenanceText: String? {
        switch provenance {
        case .converted(let sourceFormat): L10n.Configuration.Provenance.converted(sourceFormat)
        case .coreML: L10n.Configuration.Provenance.coreML
        case nil: nil
        }
    }

    private func loadProvenance() {
        // A row can be re-evaluated for an object mid-deletion; its attributes are nullified and
        // reading them traps. A deleted (or context-less) object needs no provenance — it's leaving.
        guard configuration.isDeleted.not, configuration.managedObjectContext != nil else { return }
        // A demo model ships compiled in the bundle and has no configuration directory to read.
        guard configuration.demo.not else {
            provenance = .coreML
            return
        }
        guard let directory = FileManager.deepConfigurationDirectory(id: configuration.entityId) else { return }
        provenance = ModelProvenance.read(in: directory)
    }
}

#if DEBUG
// MARK: - Preview

#Preview {
    let manager = DrawerManager()
    manager.isOpen = true
    let state = AppState.preview

    return DrawerContainer(manager: manager) {
        Color.blue.opacity(0.2)
    } menu: {
        DrawerContent()
            .environment(manager)
            .environmentObject(state.chromeState)
            .environmentObject(state.detectionState)
            .environmentObject(state.deep)
            .environmentObject(state.downloader)
            .environmentObject(state.settings)
            .environment(\.managedObjectContext, state.dataController.container.viewContext)
    }
}
#endif
