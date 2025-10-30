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
		predicate: NSPredicate(format: "entityId != nil")
	) var configurations: FetchedResults<DeepConfiguration>

	@State private var refreshToggle: Bool = false // to enforce the component's refresh (not happen always, issue on iOS16)

	@Binding var selectedConfigurationId: UUID?
	@Binding var presentedSideMenu: Bool
	@State var onAddCell: (() -> Void)
	@State var onDownloadTap: (() -> Void)

	var body: some View {
		HStack(alignment: .bottom) {
			ZStack{
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
							.padding(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 0))
							Spacer()
							Button(action: {
								presentedSideMenu = false
							}) {
								Text("Close")
									.bold()
									.foregroundColor(.blue)
							}
							.padding()
						}
					}

					List {
						Section("Available Models") {
							Group {
								if(configurations.isEmpty && isFirstLaunch.not) {
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
}
