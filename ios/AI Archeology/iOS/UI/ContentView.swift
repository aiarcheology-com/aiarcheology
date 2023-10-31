//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI


import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    private let defaultNavigationBarHeight = 44.0
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
                NavigationStack {
                    ZStack {
                        EmptyView()
							.navigationBarItems( leading: Screens.barItems(.web, position: .leading))
							.navigationBarItems( trailing: Screens.barItems(.web, position: .trailing))
						WebScreen.content()
                    }.navigationBarTitleDisplayMode(.inline)
                }
                .tabItem {
					Screens.tabItem(.web, selection: tabbarSelection)
                }
				.tag(AppMode.web)

                NavigationStack {
                    ZStack {
                        EmptyView()
							.navigationBarItems( leading: Screens.barItems(.gallery, position: .leading))
							.navigationBarItems( trailing: Screens.barItems(.gallery, position: .trailing))
						Screens.content(.gallery)
                    }
                }
				.tabItem {
					Screens.tabItem(.gallery, selection: tabbarSelection)
				}
                .tag(AppMode.gallery)

				NavigationStack {
					ZStack {
						EmptyView()
							.navigationBarItems( leading: Screens.barItems(.cloud, position: .leading))
							.navigationBarItems( trailing: Screens.barItems(.cloud, position: .trailing))
						Screens.content(.cloud)
					}
				}
				.tabItem {
					Screens.tabItem(.cloud, selection: tabbarSelection)
				}
				.tag(AppMode.cloud)

				NavigationStack {
					ZStack {
						EmptyView()
							.navigationBarItems( leading: Screens.barItems(.camera, position: .leading))
							.navigationBarItems( trailing: Screens.barItems(.camera, position: .trailing))
						Screens.content(.camera)
					}
				}
				.tabItem {
					Screens.tabItem(.camera, selection: tabbarSelection)
				}
				.tag(AppMode.camera)
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
