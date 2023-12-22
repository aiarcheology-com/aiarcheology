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
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
		predicate: NSPredicate(format: "entityId != nil"), // TODO: This is a workaround. OnAppear is called multiple times, which creates multiple instances from DownloadItem - not desired behaviour
		animation: .default)
	private var downloadItems: FetchedResults<DownloadItem>
	@Binding var showUrlPicker: Bool
	let configurationId: UUID
	var onDownload: (URL, UUID) -> Void

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
							DownloadItem.delete(entityId, in: moc)
						}) {
							Label("", systemImage: "trash")
						}
					}
				}
			}
			.listStyle(InsetGroupedListStyle())
			.navigationBarTitle("Models", displayMode: .inline)
			.navigationBarItems(trailing:	Button {
				_ = DownloadItem.create(in: moc)
			} label: {
				Image(systemName: "plus").foregroundColor(.blue)
			}
			)
		}
	}

	private func isImportButton(_ item: DownloadItem) -> Bool {
		item.entityId.isNotNil &&
		item.state == .completed &&
		item.url.isNotNil &&
		item.url?.absoluteString.isEmpty == false
	}

	private func importButton(_ item: DownloadItem) -> some View {
		Button("Import") {
			guard let file = item.file, let entityId = item.entityId else { return }
			onDownload(file, entityId)
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

fileprivate struct ListItemView: View {
	@ObservedObject var item: DownloadItem

	var body: some View {
		HStack {
			VStack {
				HStack {
					if let fileName = item.url?.lastPathComponent.fileName {
						Text(fileName)
					} else {
						Text("Edit")
							.foregroundColor(.blue)
					}
					Spacer()
				}
				HStack {
					Text(item.state.id)
						.foregroundColor(.gray)
						.font(.caption)
					Spacer()
				}
			}
		}
	}
}

fileprivate struct DownloadDetailView: View {
	@Environment(\.managedObjectContext) var moc
	@EnvironmentObject var downloader: Downloader
	@State private var urlText: String = ""
	@State private var isFormValid: Bool = false // TODO: use PreferenceKey to validate the components
	@ObservedObject var item: DownloadItem

	var body: some View {
		if item.entityId.isNotNil {
			Group {
				VStack {
					ProgressView(value: item.progress)
						.progressViewStyle(LinearProgressViewStyle())
						.frame(height: 4)
					Form {
						Section {
							HStack {
								Text("URL")
								Spacer()
								TextField("                     https://.../mymodel.mlmodel", // TODO: alignment of the hint on the trailing side
										  text: $urlText, axis: .vertical)
								.disabled([Downloader.State.downloading, Downloader.State.paused].contains(item.state))
								.lineLimit(3)
								.autocapitalization(.none)
								.disableAutocorrection(true)
								.multilineTextAlignment(.trailing)
								.onChange(of: urlText) { value in
									item.url = URL(string: urlText)

									let invalidURLs = ["https:", "http:", "https://", "http://", "https:/", "http:/"]
									if invalidURLs.contains(value) {
										isFormValid = false
										return
									}
									guard let url = URL(string: value) else {
										isFormValid = false
										return
									}
									if UIApplication.shared.canOpenURL(url) {
										isFormValid = true
									}
								}
							}
						}

						Section {
							HStack {
								Text("Status")
								Spacer()
								Text(item.state.id)
									.foregroundColor(.gray)
							}
							HStack {
								Text("Downloaded")
								Spacer()
								Text("4d85/4988395MB")
									.foregroundColor(.gray)
							}
							if let error = item.error {
								HStack {
									Text("Error")
										.foregroundColor(.red)
									Spacer()
									Text(error)
										.multilineTextAlignment(.trailing)
										.lineLimit(5)
										.foregroundColor(.gray)
								}
							}
						}
					}
					HStack {
						Spacer()
						Button(Self.downloadButtonAttributes(item.state).label, action: {
							DownloadItem.save(in: moc)
							Task {
								item.error = nil
								await downloader.downloadTapped(item)
							}
						})
						.buttonStyle(PressableButtonStyle(color: isFormValid ? Self.downloadButtonAttributes(item.state).color : .gray))
						.disabled(Self.downloadButtonAttributes(item.state).enabled.not)
						Spacer()
						Button(Self.cancelButtonAttributes(item.state).label, action: {
							Task {
								// TODO: add alert if "This action will replace the already downloaded file! Do you really want it?"
								await downloader.cancelTapped(item)
							}
						})
						.buttonStyle(PressableButtonStyle(color: Self.cancelButtonAttributes(item.state).color))
						.disabled(Self.cancelButtonAttributes(item.state).enabled.not)
						Spacer()
					}
					.centerInParentView()
				}
			}
			.onAppear {
				#if false //debugging data
				// item.url = URL(string: "http://172.20.10.13:2343/HroudaDetector.mlmodel")
				item.url = URL(string: "http://192.168.178.49:2344/HroudaDetector.mlmodel")
				isFormValid = true
				#endif
				urlText = item.url?.absoluteString ?? ""
			}
		}
	}

	static func downloadButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted: return (enabled: true, color: .blue, label: "Download")
		case .cancelled, .failed, .completed: return (enabled: true, color: .blue, label: "Restart Download")
		case .paused: return (enabled: true, color: .green, label: "Continue Download")
		case .downloading: return (enabled: true, color: .orange, label: "Pause Download")
		}
	}

	static func cancelButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .cancelled, .failed, .completed: return (enabled: false, color: .gray, label: "Cancel Download")
		case .paused, .downloading: return (enabled: true, color: .red, label: "Cancel Download")
		}
	}

}

