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
                    .onTapGesture {
						presentedSideMenu.toggle()
                    }
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
	@EnvironmentObject var guide: Guide
	@Binding var selectedSideMenuTab: Int

    var body: some View {
		HStack(alignment: .bottom) {
            ZStack{
				List {
					Section("Available Models") {
						ForEach(SideMenuRowType.allCases, id: \.self) { row in
							Button {
								selectedSideMenuTab = row.rawValue
								guide.togglingSideMenu()
							} label: {
								Text(row.title)
							}
						}
					}
				}
				.listStyle(InsetGroupedListStyle())
				.padding(.top, 30)
				.frame(width: 270)
            }
			.background(.ultraThinMaterial)
            Spacer()
        }
        .background(.clear)
    }
}
