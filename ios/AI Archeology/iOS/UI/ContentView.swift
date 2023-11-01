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
    @State var selectedSideMenuTab = 0


    var body: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
				ForEach(AppMode.tabOrder) { mode in
					ViewContainer( {
						Screens.content(mode)
							.environmentObject(appState)
					},
					leadingItems: {
						Screens.barItems(mode, position: .leading)
							.environmentObject(appState.guide)
					},
					trailingItems: {
						Screens.barItems(mode, position: .trailing)
							.environmentObject(appState.guide)
					})
					.tabItem {
						Screens.tabItem(mode, selection: tabbarSelection)
					}
					.tag(mode)
				}
            }
			SideMenu {
				SideMenuView(selectedSideMenuTab: $selectedSideMenuTab)
					.onChange(of: selectedSideMenuTab) { newValue in
						shouldCapture = true
					}
			}
			.environmentObject(appState.guide)
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
