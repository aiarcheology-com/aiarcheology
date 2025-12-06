//
//  DownloaderView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import SwiftUI

struct DownloaderView: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var downloader: Downloader
    @EnvironmentObject var deep: DeepState
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
        predicate: NSPredicate(
            format: "%K IN %@",
            #keyPath(DownloadItem.lifeCycleString),
            [
                CoreDataManageableState.empty.rawValue,
                CoreDataManageableState.draft.rawValue,
                CoreDataManageableState.ready.rawValue
            ]
        ),
        animation: .default
    )
    private var downloadItems: FetchedResults<DownloadItem>

    var onImport: ImportHandler
    
    var body: some View {
        // List of downloaded files, or currently being downloaded:
        List(downloadItems, id: \.entityId) { item in
            NavigationLink(destination:
                DownloadDetailView(item: item, onImport: onImport)
                    .environmentObject(downloader)
            ) {
                ListItemView(item: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive, action: {
                            delete(item)
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .testability(Testability.Button.downloaderListItemDelete)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            delete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .testability(Testability.NavigationLink.downloaderListItem)
        }
        .testability(Testability.List.downloaderList)
        .macOnly { view in
            view.listStyle(.inset)
        }
        .mobileOnly { view in
            view.listStyle(InsetGroupedListStyle())
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
                .testability(Testability.Button.downloaderDone)
                .bold()
                .foregroundColor(.blue)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    _ = DownloadItem.create(in: moc)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
                .testability(Testability.Button.downloaderAddDownload)
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
