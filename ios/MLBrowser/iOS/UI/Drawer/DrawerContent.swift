//
//  DrawerContent.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import CoreData

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
    @EnvironmentObject private var chromeState: AppChromeState
	@EnvironmentObject private var appState: AppState
    /// Not used by DrawerContent itself — forwarded into the Settings sheet, which needs it
    /// (env objects don't cross a `.sheet` boundary on Mac/Designed-for-iPad). AIA-0391.
    @EnvironmentObject private var detectionState: DetectionSessionState
    @EnvironmentObject private var deep: DeepState
    @EnvironmentObject private var downloader: Downloader
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var subscriptionState: SubscriptionState
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
    @State private var showSettings = false

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
                .navigationTitle(L10n.Models.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showImport, onDismiss: presentTypeReviewIfNeeded) {
            ModelImportView(
                onImported: { importedForReviewId = $0 },
                catalogProviders: appState.catalogProviders,
                catalogSearchManager: appState.catalogSearchManager
            )
                .environmentObject(deep)
                .environmentObject(downloader)
                // Environment objects do not reliably cross `.sheet` boundaries on Mac
                // (Designed for iPad) — re-inject, per AGENTS.md §3 (AIA-0350).
                .environmentObject(appState.featureFlags)
				.environmentObject(analytics)
        }
        .sheet(item: $selectedConfigurationId, onDismiss: { typeReviewConfigId = nil }) { configId in
            if let config = deep.selectConfiguration(configId) {
                ConfigurationForm(pendingTypeReview: configId == typeReviewConfigId)
                    .environmentObject(deep)
                    .environmentObject(config)
            }
        }
        .sheet(isPresented: $showFindings) {
            FindingsListView { url in
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
        }
        .sheet(isPresented: $showSettings) {
            SettingsForm()
                .environmentObject(settings)
                .environmentObject(chromeState)
                .environmentObject(detectionState)
                .environmentObject(subscriptionState)
				.environmentObject(analytics)
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
        guard let id = importedForReviewId else { return }
        importedForReviewId = nil
        typeReviewConfigId = id
        selectedConfigurationId = id
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

    private var findingsSection: some View {
        Section {
            Button {
                showFindings = true
            } label: {
                Label(L10n.Findings.title, systemImage: "archivebox")
            }
            .testability(Testability.Button.drawerFindings)
            // During the tour the whole drawer is the spotlight; keep only the model toggles
            // interactive so the user can't wander off into Findings (AIA-0333).
            .disabled(tour.isActive)
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                showSettings = true
            } label: {
                Label(L10n.Settings.title, systemImage: "gearshape")
            }
            .testability(Testability.Button.drawerSettings)
            .disabled(tour.isActive)
        }
    }
    
    private var emptyStateView: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text(L10n.Models.Empty.title)
                    .font(.headline)

                Text(L10n.Models.Empty.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
    
    private var configurationsSection: some View {
        Section(L10n.Models.Available.title) {
            // Use objectID for identity - it's always valid even for deleted objects.
            // Using entityId crashes when Core Data nullifies it during deletion.
            ForEach(configurations, id: \.objectID) { configuration in
                // Capture entityId early, before any async operations could invalidate it
                let entityId = configuration.entityId
                ConfigurationRow(
                    configuration: configuration,
                    tour: tour,
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
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showImport = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .tint(.blue)
            .accessibilityLabel("Add Model")
            // Keep only the model toggles interactive during the tour (AIA-0333).
            .disabled(tour.isActive)
        }

        ToolbarItem(placement: .topBarTrailing) {
            // A plain cross balances the leading plus symbol, keeping the inline
            // title visually centered between the two.
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

/// Ensures a demo model is enabled for the onboarding tour's overlay-driven enable step
/// (AIA-0333). Returns `true` if a demo model is enabled afterwards — including the **Replay**
/// case where one is already on (so the step isn't stuck), and only `false` when there are no
/// ready demo models at all or the save fails.
private func enableFirstReadyDemoModel(in context: NSManagedObjectContext) -> Bool {
    let demos = DeepConfiguration.selectAll(in: context)
        .filter { $0.demo && $0.lifeCycleString == CoreDataManageableState.ready.rawValue }
    guard demos.isEmpty == false else { return false }

    // Newest-first (matching the list) so it flips the top, spotlighted row. If they're all
    // already enabled (Replay), the step's goal already holds — proceed.
    guard let target = demos
        .filter({ $0.enabled == false })
        .max(by: { ($0.creationDate_ ?? .distantPast) < ($1.creationDate_ ?? .distantPast) })
    else {
        return true
    }
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
