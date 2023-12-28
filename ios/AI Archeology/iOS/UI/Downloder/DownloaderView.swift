//
//  DownloaderView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import SwiftUI

struct DownloaderView: View {
	@Environment(\.horizontalSizeClass) var sizeClass
	@Environment(\.managedObjectContext) var moc
	@EnvironmentObject var downloader: Downloader
	@EnvironmentObject var deep: DeepState
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
		predicate: NSPredicate(format: "entityId != nil"), // TODO: This is a workaround. OnAppear is called multiple times, which creates multiple instances from DownloadItem - not desired behaviour
		animation: .default)
	private var downloadItems: FetchedResults<DownloadItem>
	@Binding var showUrlPicker: Bool
	let configurationId: UUID
	var onDownload: (URL, UUID, ModelProvider) -> Void

	var body: some View {
		NavigationView {
			// List of downloaded files, or currently being downloaded:
			List(downloadItems, id: \.entityId) { item in
				NavigationLink(destination:
					DownloadDetailView(item: item)
					.environmentObject(downloader)
					.navigationBarTitle("Model", displayMode: .inline)
					.navigationBarItems(leading: detailNavLeadingButton(item))
					.navigationBarItems(trailing: detailNavTrailingButton(item))
				) {
				ListItemView(item: item)
					.swipeActions {
						Button(role: .destructive, action: {
							guard let entityId = item.entityId else {
								assert(false, "No entry has been found after the selection.")
								return
							}
							// ifConfig.isNil: The model has not been imported. Remove it.
							// ifConfig.isNotNil: The model has been imported. Keep it.
							let ifConfig = deep.selectConfiguration(entityId)
							DownloadItem.delete(item, in: moc, deleteModel: ifConfig.isNil)
						}) {
							Label("", systemImage: "trash")
						}
					}
				}
			}
			.listStyle(InsetGroupedListStyle())
			.navigationBarTitle("Models", displayMode: .inline)
			.navigationBarItems(leading:
				Button {
					showUrlPicker = false
				} label: {
					Image(systemName: "plus")
						.rotationEffect(.radians(.pi/4))
						.foregroundColor(.blue)
				}
					.foregroundColor(.blue)

				)
			.navigationBarItems(trailing:
				HStack {
					Button {
						_ = DownloadItem.create(in: moc)
					} label: {
						Image(systemName: "plus.circle.fill")
							.foregroundColor(.blue)
					}
				}
			)
		}
	}

	private func isImportButton(_ item: DownloadItem) -> Bool {
		item.entityId.isNotNil &&
		item.state == .completed &&
		item.url.isNotNil &&
		item.url?.absoluteString.isEmpty == false &&
		item.doesModelFileExist()
	}

	private func importButton(_ item: DownloadItem) -> some View {
		Button("Import") {
			guard let file = item.file, let entityId = item.entityId else { return }
			onDownload(file, entityId, downloader)
			showUrlPicker = false
		}
		.bold()
		.foregroundColor(isImportButton(item).enabled ? .green : .gray)
		.disabled(isImportButton(item).enabled.not)
	}

	@ViewBuilder
	private func detailNavLeadingButton(_ item: DownloadItem) -> some View {
		if sizeClass == .compact {
			EmptyView()
		} else {
			importButton(item)
		}
	}

	@ViewBuilder
	private func detailNavTrailingButton(_ item: DownloadItem) -> some View {
		if sizeClass == .compact {
			importButton(item)
		} else {
			Button("Dismiss") {
				showUrlPicker = false
			}
			.bold()
			.foregroundColor(.blue)
		}
	}
}

