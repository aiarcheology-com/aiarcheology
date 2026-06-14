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
    @EnvironmentObject private var guide: Guide
    @EnvironmentObject private var deep: DeepState
    @EnvironmentObject private var downloader: Downloader
    @EnvironmentObject private var settings: Settings
    
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
    
    var body: some View {
        NavigationStack {
            configurationList
                .navigationTitle(L10n.Models.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showImport) {
            ModelImportView()
                .environmentObject(deep)
                .environmentObject(downloader)
        }
        .sheet(item: $selectedConfigurationId) { configId in
            if let config = deep.selectConfiguration(configId) {
                ConfigurationForm()
                    .environmentObject(deep)
                    .environmentObject(config)
            }
        }
        .sheet(isPresented: $showFindings) {
            FindingsListView { url in
                // Open the captured page: tear down this sheet and the drawer,
                // then hand the URL to the web screen via the Guide.
                showFindings = false
                drawer.close()
                guide.pageToOpen = url
            }
            // Re-inject the context: on Mac (Designed for iPad) SwiftUI does not
            // reliably carry \.managedObjectContext across the sheet boundary, so
            // the fetch/distinctLabels would hit the empty default context and crash.
            .environment(\.managedObjectContext, moc)
        }
        .sheet(isPresented: $showSettings) {
            SettingsForm()
                .environmentObject(settings)
                .environmentObject(guide)
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
        // The drawer is a fixed-width panel anchored at the leading edge. In landscape the
        // List would otherwise inset its content by the device's leading safe area (the
        // Dynamic Island side), wasting a gutter inside the panel. The panel is the safe
        // container here, so let the List span its full width in both orientations.
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var findingsSection: some View {
        Section {
            Button {
                showFindings = true
            } label: {
                Label(L10n.Findings.title, systemImage: "archivebox")
            }
            .testability(Testability.Button.drawerFindings)
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
                    onTap: {
                        selectedConfigurationId = entityId
                    },
                    onDelete: {
                        DeepConfiguration.delete(entityId, in: moc)
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
        }
    }
}

// MARK: - Configuration Row

/// A single row in the configurations list.
/// Uses `.buttonStyle(.borderless)` to isolate gesture handling, enabling
/// swipe actions to coexist with Toggle on all platforms.
private struct ConfigurationRow: View {
    @ObservedObject var configuration: DeepConfiguration
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.modelDescription ?? "Unnamed Model")
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .testability(Testability.Label.sideMenuCellDescription)
                
                if let author = configuration.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { configuration.enabled },
                set: { newValue in
                    configuration.enabled = newValue
                    if let context = configuration.managedObjectContext {
                        do {
                            try DeepConfiguration.save(in: context)
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
    }
}

// MARK: - Preview

#Preview {
    let manager = DrawerManager()
    manager.isOpen = true
    let state = AppState()

    return DrawerContainer(manager: manager) {
        Color.blue.opacity(0.2)
    } menu: {
        DrawerContent()
            .environment(manager)
            .environmentObject(state.guide)
            .environmentObject(state.deep)
            .environmentObject(state.downloader)
            .environmentObject(state.settings)
            .environment(\.managedObjectContext, state.dataController.container.viewContext)
    }
}
