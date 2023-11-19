//
//  SideMenu.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 21.09.23.
//

import SwiftUI

enum SideMenuRowType: Int, CaseIterable{
    case home = 0
    case favorite
    case chat
    case profile

    var title: String{
        switch self {
        case .home:
            return "Fortification detection"
        case .favorite:
            return "Fortification detection"
        case .chat:
            return "Enclosure detection"
        case .profile:
            return "Mound dection"
        }
    }

    var iconName: String{
        switch self {
        case .home:
            return "home"
        case .favorite:
            return "favorite"
        case .chat:
            return "chat"
        case .profile:
            return "profile"
        }
    }
}

class SideMenuData: ObservableObject {
	@Published var id: UUID
	@Published var title: String
	@Published var enabled: Bool

	init(id: UUID, title: String, enabled: Bool) {
		self.id = id
		self.title = title
		self.enabled = enabled
	}
}

struct SideMenuCell: View {
	@EnvironmentObject var data: SideMenuData

	var body: some View {
		HStack {
			Text(data.title)
			Spacer()
			Toggle("", isOn: $data.enabled)
			.labelsHidden()
		}
	}
}

struct SideMenu<Content: View>: View {
	@Binding var presentedSideMenu: Bool

	let content: Content
    var edgeTransition: AnyTransition = .move(edge: .leading)
    var body: some View {
        ZStack(alignment: .bottom) {
			if (presentedSideMenu) {
                Color.black
                    .opacity(0.3)
                    .ignoresSafeArea()
                content
                    .transition(edgeTransition)
                    .background(
                        Color.clear
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
		.animation(.easeInOut, value: presentedSideMenu)
    }

	@inlinable public init(presentedSideMenu: Binding<Bool>, @ViewBuilder _ content: () -> Content) {
		self.content = content()
		self._presentedSideMenu = presentedSideMenu
	}
}

struct SideMenuView: View {
	@State var cells: [SideMenuData]
	@Binding var selectedSideMenuTab: Int
	@Binding var presentedSideMenu: Bool
	@State var onAddCell: (() -> Void)

    var body: some View {
		HStack(alignment: .bottom) {
            ZStack{
				VStack {
					// Dismiss button
					VStack {
						HStack {
							Button(action: onAddCell) {
								Image(systemName: "plus")
							}
							.padding()
							Spacer()
							Button(action: {
								presentedSideMenu = false
							}) {
								Text("Close")
									.bold()
							}
							.padding()
						}
					}

					List {
						Section("Available Models") {
							ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
								Button {
									selectedSideMenuTab = index
								} label: {
									SideMenuCell()
										.environmentObject(cell)
										.onChange(of: cell.enabled) { value in
											print(cell.id)
										}
								}
							}
						}
					}
					.listStyle(InsetGroupedListStyle()) //TODO: ultraThinMaterial background?
				}
				.padding(.top, 30)
				.frame(width: 270)
            }
			.background(.ultraThinMaterial)
            Spacer()
        }
        .background(.clear)
    }
}
