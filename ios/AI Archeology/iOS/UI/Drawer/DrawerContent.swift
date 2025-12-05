//
//  DrawerContent.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI
import CoreData

/// The content displayed inside the drawer for AI Archeology.
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
                .navigationTitle("Models")
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
                
                Text("No Models")
                    .font(.headline)
                
                Text("Tap the + button to add your first ML model.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
    
    private var configurationsSection: some View {
        Section("Available Models") {
            ForEach(configurations, id: \.entityId) { configuration in
                ConfigurationRow(configuration: configuration) {
                    selectedConfigurationId = configuration.entityId
                }
            }
            .onDelete(perform: deleteConfigurations)
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
            Button("Close") {
                drawer.close()
            }
            .bold()
            .tint(.blue)
        }
    }
    
    // MARK: - Actions
    
    private func deleteConfigurations(at offsets: IndexSet) {
        for index in offsets {
            let configuration = configurations[index]
            DeepConfiguration.delete(configuration.entityId, in: moc)
        }
    }
}

// MARK: - Configuration Row

/// A single row in the configurations list
private struct ConfigurationRow: View {
    @ObservedObject var configuration: DeepConfiguration
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
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
                        DeepConfiguration.save(in: configuration.managedObjectContext!)
                    }
                ))
                .tint(configuration.annotationColor)
                .labelsHidden()
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                if let context = configuration.managedObjectContext {
                    DeepConfiguration.delete(configuration.entityId, in: context)
                }
            } label: {
                Label("Delete", systemImage: "trash")
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
