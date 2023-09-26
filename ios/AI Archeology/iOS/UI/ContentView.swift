//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import CoreData
import Vision


import SwiftUI
import Combine

//TODO: Only for demo scene
struct ImageGalleryApp: View {
    @StateObject var dataModel = DataModel()

    var body: some View {
        GridView()
        .environmentObject(dataModel)
    }
}

import WebKit
public class TakeScreenShotCommand {
    var screenShot: UIImage?
    func takeScreenShot(_ webview: WKWebView) {
        webview.takeSnapshot(with: nil, completionHandler: { image, error in
            if let image = image {
                self.screenShot = image
            }
        })
    }
}

struct FirstItem: View {

    @StateObject var viewModel = TextViewModel()
//    var websiteUrl: CurrentValueSubject<String, Never> = .init("")
    @State private var websiteUrl: String = "https://ags.cuzk.cz/av/?extent=-831332.9688214378,-1117345.0500381005,-639820.6497967998,-1016468.2402844809&zvd=dmr5g&rf=GrayscaleHillshade&o=0"
    @State private var isWebsiteLoading: Bool = false
    @State private var inputUrl: String = ""

    @Binding var shouldCapture: Bool
    @State var capturedImage: UIImage?
    // Initialize the object detector
    let objectDetector = ObjectDetector()
    let screenShotCommand = TakeScreenShotCommand()

    @State private var observations: [VNRecognizedObjectObservation] = []

    var body: some View {
        // probably there should be a common impl for all capturable tabs.
        // Each capturable tab should have its own impl of image capture and maybe later also a detection
        ZStack {
            Image(uiImage: capturedImage ?? UIImage())
                .resizable()
                .overlay(DetectionOverlayView(observations: observations))

            AntWebView(websiteUrl, capturedImageChanged: { image in
                if shouldCapture == true {

                    // Trigger object detection
                    objectDetector.detectObjects(in: image) { newObservations  in
                        if let newObservations {
                            self.observations = newObservations
                        }
                    }
                    shouldCapture = false // Reset the flag
                }
            }) { loading, error in
                print("loading status : \(loading)")
            }
            .clipped()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // TODO: change the url in the text field,
                    // when it is updated in the webview component
                    // maybe move to some model...
                    TextField("website url", text: $inputUrl)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit(of: .text, {
                            self.websiteUrl = inputUrl
                        })
                }
            }
        }
    }
}

struct ContentView: View {
    // TODO: remove the code and use some sensible api:
    // Only for the desing sessions.
    private let defaultNavigationBarHeight = 44.0
    @State var tabbarSelection = 0
    init() {
        // To keep the navigation/tab bar non-transparent when using
        // an Image view.
        let appearance = UINavigationBarAppearance()
        appearance.backgroundColor = .systemBackground // You can set this to your preferred color
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().backgroundColor = .systemBackground
        UITabBar.appearance().unselectedItemTintColor = UIColor.gray
    }

    @State var shouldCapture: Bool = false


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
                                }, label: { Image(systemName: "cpu").foregroundColor(.gray)})
                            }
                            )

                            .navigationBarItems( trailing:
                                                    HStack {
                                Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray)})
                                Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray)})
                                Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray)})
                            }
                            )
                        VStack {
                            FirstItem(shouldCapture: $shouldCapture)
                        }
                    }.navigationBarTitleDisplayMode(.inline)
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
                    if tabbarSelection == 2 {
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
                    if tabbarSelection == 3 {
                        Image(systemName: "archivebox.fill")
                    } else {
                        Image(systemName:"archivebox").environment(\.symbolVariants, .none)
                    }
                    Text("API")
                }
                .tag(3)
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
                        ZStack{
                            Color.black
                            Image("DemoVideo")

                        }
                        .foregroundColor(.black)
                        .scaledToFit()
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationTitle("Drone 02 - Online(TCP)")
                    }
                }
                .tabItem {
                    if tabbarSelection == 4 {
                        Image(systemName: "video.fill")
                    } else {
                        Image(systemName:"video").environment(\.symbolVariants, .none)
                    }
                    Text("Stream")
                }
                .tag(4)
            }
            SideMenu(isShowing: $presentSideMenu, content: AnyView(SideMenuView(selectedSideMenuTab: $selectedSideMenuTab, presentSideMenu: $presentSideMenu)))
                .onChange(of: selectedSideMenuTab) { newValue in
//                    shouldCapture = true
                }
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
