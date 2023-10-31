//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
	@State var tabbarSelection: AppMode = .web

    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }

    @State var shouldCapture: Bool = false
    @State var presentSideMenu = false
    @State var selectedSideMenuTab = 0


    var body: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
				ForEach(AppMode.tabOrder) { mode in
					ViewContainer( {
						Screens.content(mode)
					},
					leadingItems: {
						Screens.barItems(mode, position: .leading)
					},
					trailingItems: {
						Screens.barItems(mode, position: .trailing)
					})
					.tabItem {
						Screens.tabItem(mode, selection: tabbarSelection)
					}
					.tag(mode)
					.environmentObject(appState)
				}
            }
            SideMenu(isShowing: $presentSideMenu, content: AnyView(SideMenuView(selectedSideMenuTab: $selectedSideMenuTab, presentSideMenu: $presentSideMenu)))
                .onChange(of: selectedSideMenuTab) { newValue in
                    shouldCapture = true
                }
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
