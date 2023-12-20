//
//  DownloaderView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import SwiftUI

struct DownloaderView: View {
	@Binding var showUrlPicker: Bool
	@Environment(\.managedObjectContext) var moc
	@EnvironmentObject var downloader: Downloader
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)],
		predicate: NSPredicate(format: "entityId != nil"), // TODO: This is a workaround. OnAppear is called multiple times, which creates multiple instances from DownloadItem - not desired behaviour
		animation: .default)
	private var downloadItems: FetchedResults<DownloadItem>

	@State private var isFormValid: Bool = false
	@State private var urlText: String = ""
	@State private var fromListSelectedDownloadItem: DownloadItem?
	private var selectedDownloadItem: Binding<DownloadItem?> {
		Binding (
			get: { fromListSelectedDownloadItem ?? downloadItems.first },
			set: {_ in }
		)
	}


	var body: some View {
		NavigationView {
				// List of downloaded files, or currently being downloaded:
			List(downloadItems, id: \.entityId) { (item: DownloadItem) in
				HStack {
					Text(item.url?.lastPathComponent ?? "Unknown File")
					Spacer()
					Text(item.state.id)
						.foregroundColor(.gray)
						.font(.caption)
				}
				.swipeActions {
					Button(role: .destructive, action: {
						guard let entityId = item.entityId else {
							assert(false, "No entry has been found after the selection.")
							return
						}
						DownloadItem.delete(entityId, in: moc)
						self.fromListSelectedDownloadItem = nil

					}) {
						Label("", systemImage: "trash")
					}
				}
				.onTapGesture {
					self.fromListSelectedDownloadItem = item
				}
			}
			.listStyle(SidebarListStyle())
			.navigationBarTitle("Models", displayMode: .inline)
			.navigationBarItems(trailing:	Button {
				self.fromListSelectedDownloadItem = DownloadItem.create(in: moc)
			} label: {
				Image(systemName: "plus").foregroundColor(.blue)
			}
			)


				// Detail view:
				Group {
				if let selectedDownloadItem = selectedDownloadItem.wrappedValue {
					VStack {
						ProgressView(value: selectedDownloadItem.progress)
							.progressViewStyle(LinearProgressViewStyle())
							.frame(height: 4)
						Form {
							Section {
								HStack {
									Text("URL")
									Spacer()
									TextField("                     https://.../mymodel.mlmodel",
											  text: $urlText, axis: .vertical)
									.disabled([Downloader.State.downloading, Downloader.State.paused].contains(selectedDownloadItem.state))
									.lineLimit(3)
									.autocapitalization(.none)
									.disableAutocorrection(true)
									.multilineTextAlignment(.trailing)
									.onChange(of: urlText) { value in
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
											selectedDownloadItem.url = url
											isFormValid = true
										}
									}
									.onChange(of: selectedDownloadItem) { newValue in
										urlText = newValue.url?.absoluteString ?? ""
									}
								}
							}

							Section {
								HStack {
									Text("Status")
									Spacer()
									Text(selectedDownloadItem.state.id)
										.foregroundColor(.gray)
								}
								HStack {
									Text("Downloaded: ")
									Spacer()
									Text("4d85/4988395MB")
										.foregroundColor(.gray)
								}
							}
						}
						HStack {
							Spacer()
							Button(Self.downloadButtonAttributes(selectedDownloadItem.state).label, action: {
								downloader.downloadTapped(selectedDownloadItem)
								DownloadItem.save(in: moc)
							})
							.buttonStyle(PressableButtonStyle(color: isFormValid ? Self.downloadButtonAttributes(selectedDownloadItem.state).color : .gray))
							.disabled(Self.downloadButtonAttributes(selectedDownloadItem.state).enabled.not)
							Spacer()
							Button(Self.cancelButtonAttributes(selectedDownloadItem.state).label, action: {
								downloader.cancelTapped(selectedDownloadItem)
							})
							.buttonStyle(PressableButtonStyle(color: Self.cancelButtonAttributes(selectedDownloadItem.state).color))
							.disabled(Self.cancelButtonAttributes(selectedDownloadItem.state).enabled.not)
							Spacer()
						}
						.centerInParentView()
					}
				} else {
					EmptyView()
				}
			}
			.navigationBarTitle("Download Detail", displayMode: .inline)
			.navigationBarItems(trailing:
									Button("Cancel") {
				showUrlPicker = false
			}
				.bold()
				.foregroundColor(.blue)
			)
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
