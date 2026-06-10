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
    @EnvironmentObject private var deep: DeepState
    @EnvironmentObject private var downloader: Downloader
    
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
    }
    
    // MARK: - Configuration List
    
    private var configurationList: some View {
        List {
            if configurations.isEmpty {
                emptyStateView
            } else {
                configurationsSection
            }
        }
        .listStyle(.insetGrouped)
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
            Button(L10n.Common.dismiss) {
                drawer.close()
            }
            .bold()
            .tint(.blue)
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
                
                if let author = configuration.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .buttonStyle(.borderless)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label(L10n.Common.delete, systemImage: "trash")
            }
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
    
    return DrawerContainer(manager: manager) {
        Color.blue.opacity(0.2)
    } menu: {
        DrawerContent()
            .environment(manager)
    }
}
