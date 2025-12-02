//
//  SideMenuView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct SideMenuView: View {
	var isFirstLaunch: Bool
	@Environment(\.managedObjectContext) var moc
	@FetchRequest(
		entity: DeepConfiguration.entity(),
		sortDescriptors: [
			// Most recent configuration is the first one:
			NSSortDescriptor(keyPath: \DeepConfiguration.creationDate_, ascending: false)
		],
		// Filter for configurations that are ready (filled out and validated)
		predicate: NSPredicate(
			format: "%K == %@", #keyPath(DownloadItem.lifeCycleString), CoreDataManageableState.ready.rawValue
		)
	) var configurations: FetchedResults<DeepConfiguration>
	
	@State private var refreshToggle: Bool = false // to enforce the component's refresh (not happen always, issue on iOS16)
	
	@Binding var selectedConfigurationId: UUID?
	@Binding var presentedSideMenu: Bool
	@State var onAddCell: (() -> Void)
	@State var onDownloadTap: (() -> Void)
	
	var body: some View {
		HStack(alignment: .bottom) {
			ZStack {
				VStack {
					// Dismiss button
					VStack {
						HStack {
							Button(action: onAddCell) {
								Image(systemName: "plus.circle.fill")
									.resizable()
									.foregroundColor(.blue)
									.frame(width: 24, height: 24)
							}
							.testability(Testability.Button.sideMenuAddConfiguration)
							.padding(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 0))
							Spacer()
							Button(action: {
								presentedSideMenu = false
							}) {
								Text("Close")
									.bold()
									.foregroundColor(.blue)
							}
							.testability(Testability.Button.sideMenuClose)
							.padding()
						}
					}
					
					List {
						Section("Available Models") {
							Group {
								if (configurations.isEmpty && isFirstLaunch.not) {
									VStack {
										Spacer()
										Text("Tap the ＋ icon to add a new model.")
											.foregroundColor(.gray)
										Spacer()
									}
								} else {
									if isFirstLaunch {
										VStack {
											Spacer()
											Text("Tap the ＋ icon to add a new model.")
												.foregroundColor(.gray)
											Spacer()
										}
									}
									ForEach(Array(configurations.enumerated()), id: \.offset) { index, configuration in
										Button {
											selectedConfigurationId = configuration.entityId
										} label: {
											SideMenuCell()
												.environmentObject(configuration)
												.onChange(of: configuration.enabled) { value in
													DeepConfiguration.save(in: moc)
												}
										}
										.testability(Testability.Button.sideMenuConfigurationCell, index: index)
										.contextMenu { // Context menu for macOS/right-click deletion
											Button(role: .destructive) {
												deleteConfiguration(configuration)
											}
											label: {
												Label("Delete", systemImage: "trash")
											}
											.testability(Testability.Button.sideMenuDeleteConfiguration, index: index)
										}
									}
									.onDelete { offsets in
										for index in offsets {
											let configuration = configurations[index]
											let entityId = configuration.entityId
											DeepConfiguration.delete(entityId, in: moc)
										}
									}
								}
							}
						}
					}
					.listStyle(InsetGroupedListStyle()) //TODO: ultraThinMaterial background?
				}
				.padding(.top, 25)
				.frame(width: 300)
			}
			.background(.ultraThinMaterial)
			Spacer()
		}
		.background(.clear)
	}
	
	private func deleteConfiguration(_ configuration: DeepConfiguration) {
		let entityId = configuration.entityId
		
		// If the currently selected configuration is being deleted, clear the selection
		if selectedConfigurationId == entityId {
			selectedConfigurationId = nil
		}
		
		DeepConfiguration.delete(entityId, in: moc)
	}
}
