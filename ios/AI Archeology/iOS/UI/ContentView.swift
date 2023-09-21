//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import CoreData


import SwiftUI

//TODO: Only for demo scene
struct ImageGalleryApp: View {
    @StateObject var dataModel = DataModel()

    var body: some View {
        GridView()
        .environmentObject(dataModel)
    }
}


struct ContentView: View {
    // TODO: remove the code and use some sensible api:
    // Only for the desing sessions.
    private let defaultNavigationBarHeight = 44.0
    @State var tabbarSelection = 0
    init() {
        UITabBar.appearance().unselectedItemTintColor = UIColor.gray
    }

    @State private var website: String = ""

    @State var presentSideMenu = false
    @State var selectedSideMenuTab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tabbarSelection) {
                NavigationStack {
                    ZStack {
                        EmptyView()
                            .navigationBarItems( leading:
                                                    HStack {
                                Button ( action:  {
                                    presentSideMenu.toggle()
                                }, label: { Image(systemName: "cpu").foregroundColor(.white)})
                            }
                            )

                            .navigationBarItems( trailing:
                                                    HStack {
                                Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.white)})
                                Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.white)})
                                Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.white)})
                            }
                            )
                        Image("DemoScene")
                            .resizable()
                            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
                            .scaledToFill()
                            .toolbar {
                                ToolbarItem(placement: .principal) {
                                    TextField("website url", text: $website)
                                        .textFieldStyle(.roundedBorder)
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                }
                            }
                        VStack {
                            Rectangle()
                                .frame(width: nil, height:88)
                                .background(.black)
                                .mask(LinearGradient(gradient: Gradient(colors: [.black.opacity(0.3), .clear]), startPoint: .top, endPoint: .bottom))
                                .ignoresSafeArea()
                                .allowsTightening(false)
                            Spacer()
                            //TODO: when the webview will be integrated, the gradient
                            //should be visible also in the landscape - the DemoScene image causes the
                            // gradient to be shifted too much down
                            Rectangle()
                                .frame(width: nil, height:88)
                                .background(.black)
                                .mask(LinearGradient(gradient: Gradient(colors: [.black.opacity(0.5), .clear]), startPoint: .bottom, endPoint: .top))
                                .ignoresSafeArea()
                                .offset(x: 0, y: 66)
                                .allowsTightening(false)
                        }
                    }
                }
                .tabItem {
                    if tabbarSelection == 0 {
                        Image(systemName: "map")
                    } else {
                        Image(systemName:"map").environment(\.symbolVariants, .none)
                    }
                    Text("Web")
                }
                .tag(0)

                NavigationStack {
                    ZStack {
                        EmptyView()
                            .navigationBarItems( leading:
                                                    HStack {
                                Button ( action:  {
                                    presentSideMenu.toggle()
                                }, label: { Image(systemName: "cpu").foregroundColor(.gray.opacity(0.8))})
                            }
                            )

                            .navigationBarItems( trailing:
                                                    HStack {
                                Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray.opacity(0.8))})
                            }
                            )
                        ImageGalleryApp()
                        //                            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
                        //                            .scaledToFill()
                    }
                }
                .tabItem {
                    if tabbarSelection == 1 {
                        Image(systemName: "rectangle.grid.2x2.fill")
                    } else {
                        Image(systemName:"rectangle.grid.2x2").environment(\.symbolVariants, .none)
                    }
                    Text("Gallery")
                }
                .tag(1)
                NavigationStack {
                    ZStack {
                        EmptyView()
                            .navigationBarItems( leading:
                                                    HStack {
                                Button ( action:  {
                                    presentSideMenu.toggle()
                                }, label: { Image(systemName: "cpu").foregroundColor(.gray.opacity(0.8))})
                            }
                            )

                            .navigationBarItems( trailing:
                                                    HStack {
                                Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray.opacity(0.8))})
                            }
                            )
                        ImageGalleryApp()
                        //                            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
                        //                            .scaledToFill()
                    }
                }
                .tabItem {
                    if tabbarSelection == 1 {
                        Image(systemName: "externaldrive.fill.badge.icloud")
                    } else {
                        Image(systemName:"externaldrive.badge.icloud").environment(\.symbolVariants, .none)
                    }
                    Text("Cloud")
                }
                .tag(2)
                NavigationStack {
                    ZStack {
                        EmptyView()
                            .navigationBarItems( leading:
                                                    HStack {
                                Button ( action:  {
                                    presentSideMenu.toggle()
                                }, label: { Image(systemName: "cpu").foregroundColor(.gray.opacity(0.8))})
                            }
                            )

                            .navigationBarItems( trailing:
                                                    HStack {
                                Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray.opacity(0.8))})
                                Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray.opacity(0.8))})
                            }
                            )
                        ImageGalleryApp()
                        //                            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
                        //                            .scaledToFill()
                    }
                }
                .tabItem {
                    if tabbarSelection == 1 {
                        Image(systemName: "archivebox.fill")
                    } else {
                        Image(systemName:"archivebox").environment(\.symbolVariants, .none)
                    }
                    Text("API")
                }
                .tag(3)
            }
            SideMenu(isShowing: $presentSideMenu, content: AnyView(SideMenuView(selectedSideMenuTab: $selectedSideMenuTab, presentSideMenu: $presentSideMenu)))
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
