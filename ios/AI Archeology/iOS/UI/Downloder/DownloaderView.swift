//
//  DownloaderView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import SwiftUI

struct DownloaderView: View {
    @Environment(\.managedObjectContext) private var moc
    @EnvironmentObject var downloader: Downloader
    @EnvironmentObject var deep: DeepState
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
        predicate: NSPredicate(
            format: "%K == %@", #keyPath(DownloadItem.lifeCycleString), CoreDataManageableState.ready.rawValue
        ),
        animation: .default)
    private var downloadItems: FetchedResults<DownloadItem>
    let configurationId: UUID
    var onImport: (URL, UUID, ModelProvider) -> Void
    
    var body: some View {
        // List of downloaded files, or currently being downloaded:
        List(downloadItems, id: \.entityId) { item in
            NavigationLink(destination:
                DownloadDetailView(item: item, onImport:
                    ImportHandler { url, id, provider in
                        onImport(url, id, provider)
                    }
                )
                .environmentObject(downloader)
            ) {
                ListItemView(item: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive, action: {
                            delete(item)
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            delete(item)                        }
                        label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .macOnly { view in
            view.listStyle(.inset)
        }
        .mobileOnly { view in
            view.listStyle(InsetGroupedListStyle())
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    _ = DownloadItem.create(in: moc)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private func delete(_ item: DownloadItem) {
        let entityId = item.entityId
        
        // ifConfig.isNil: The model has not been imported. Remove it.
        // ifConfig.isNotNil: The model has been imported. Keep it.
        let ifConfig = deep.selectConfiguration(entityId)
        DownloadItem.delete(item, in: moc, deleteModel: ifConfig.isNil)
    }
}
