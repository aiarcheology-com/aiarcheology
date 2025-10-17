//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import Combine


private enum ActiveSheet: Identifiable {
    case configuration
    case settings
    case slideshow
    
    var id: Int { hashValue }
}

struct ContentView: View {
    // environment:
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    // app model:
    @EnvironmentObject var appState: AppState
    // sheets, alerts and menus:
    @State private var detectedObservations: [ObservationParams] = []
    @State private var showErrorAlert = false
    @State private var addressBarMenu: [URL] = []
    @State private var errorMessage = ""
    @State private var showAnnotation = true
    // content manipulation:
    @State private var brightness = SnapAdjustment.defaultBrightness
    @State private var contrast = SnapAdjustment.defaultContrast
    @State private var saturation = SnapAdjustment.defaultSaturation
    @State private var activeSheet: ActiveSheet?
    
    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }
    
    var body: some View {
        ZStack {
            // ------ Tabs: ------
            TabView(selection: $appState.guide.mode) {
                ForEach(AppMode.tabOrder) { mode in
                    ViewContainer( {
                        Screens.content(mode)
                            .onSnapshot { image, frame in
                                appState.deep.drivers.detect(on: image) { observations in
                                    detectedObservations = observations
                                    appState.deep.frame = frame
                                }
                            }
                            .annotate(from: detectedObservations, withinFrame: appState.deep.frame) { observation, params, parentFrame, geometry  in
                                AnnotationViewBuilder(observation: observation, geometry: geometry, params: params, showIndentifiers: appState.settings.showIdentifiers)
                            }
                            .gesture( // Reset the annoation when we drag the content
                                DragGesture()
                                    .onEnded { _ in
                                        detectedObservations.removeAll()
                                    }
                            )
                        // ---- Apply the image properties to the content -----
                        // Some lidar/map/orto websites have slightly different brightnes
                        // which can be compensated by adjusting one of these properties:
                            .onReceive(appState.snapAdjustment.$brightness) { newValue in
                                brightness = newValue
                            }
                            .onReceive(appState.snapAdjustment.$contrast) { newValue in
                                contrast = newValue
                            }
                            .onReceive(appState.snapAdjustment.$saturation) { newValue in
                                saturation = newValue
                            }
                            .brightness(brightness)
                            .contrast(contrast)
                            .saturation(saturation)
                            .environmentObject(appState)
                    },
                                   leadingItems: {
                        Screens.barItems(mode, position: .leading)
                            .environmentObject(appState.guide)
                            .environmentObject(appState.downloader)
                    },
                                   trailingItems: {
                        Screens.barItems(mode, position: .trailing)
                            .environmentObject(appState.guide)
                    })
                    .tabItem {
                        Screens.tabItem(mode, selection: appState.guide.mode)
                    }
                    .tag(mode)
                }
                .toolbar(AppMode.tabOrder.count == 1 ? .hidden : .visible, for: .tabBar)
            }
            // ----- Side Menu: -----
            SideMenuLogic(isFirstLaunch: appState.settings.isFirstLaunchMarked,
                          onAddCell: {
                // Plus button triggered: -> create new configuration
                guard activeSheet == nil else { return } // avoid presenting while another sheet is up
                appState.deep.newConfiguration = appState.deep.createConfiguration()
                activeSheet = .configuration
            },
                          onDownloadTap: {
                // TODO: Open the download sheet
            },
                          onSelectCell: { entityId in
                // Configuration cell selected: -> open existing configuration
                guard activeSheet == nil else { return } // avoid presenting while another sheet is up
                appState.guide.selectedConfigurationId = entityId
                activeSheet = .configuration
            })
            .onReceive(appState.guide.$addressBarMenu) { urls in
                addressBarMenu = urls
            }
            .dropDownMenu(items: addressBarMenu, backgroundColor: colorScheme == .dark ? .black : .white, 
                          cancelContent: {
                HStack {
                    Spacer()
                    Button {
                        appState.guide.addressBarMenu = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundColor(.gray)
                    .padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 25))
                }
            }) { item in
                Button {
                    appState.guide.historySelected(item)
                } label: {
                    Text(item.absoluteString.trimmedString)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
            }
            .environmentObject(appState.guide)
            .environmentObject(appState.deep)
            // ------ Show the slideshow after the app's installation -----
        }
        .sheet(item: $activeSheet, onDismiss: {
            // centralize your cleanup that used to live in each onDismiss
            if appState.deep.newConfiguration?.entityId.isNil == true,
               let newConfiguration = appState.deep.newConfiguration {
                DeepConfiguration.delete(newConfiguration, in: appState.dataController.container.viewContext)
            }
            appState.deep.newConfiguration = nil
            appState.guide.selectedConfigurationId = nil
        }) { sheet in
            switch sheet {
            case .slideshow:
                SlideshowView()
                    .centerInParentView()
                    .environmentObject(appState.settings)
                
            case .settings:
                SettingsForm()
                    .environmentObject(appState.settings)
                    .environmentObject(appState.guide)
                
            case .configuration:
                if let config = appState.deep.newConfiguration {
                    ConfigurationForm()
                        .environmentObject(config)
                        .environmentObject(appState.deep)
                        .environmentObject(appState.downloader)
                } else if let id = appState.guide.selectedConfigurationId,
                          let config = appState.deep.selectConfiguration(id) {
                    ConfigurationForm()
                        .environmentObject(config)
                        .environmentObject(appState.deep)
                        .environmentObject(appState.downloader)
                } else {
                    // Optional: a fallback view if nothing is selected
                    Text("No configuration available")
                }
            }
        }
        .onReceive(appState.guide.$presentSettings) { present in
            activeSheet = present ? .settings : nil
        }
        .onReceive(appState.deep.$deepStateError) { error in
            guard let error else { return }
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(title: Text("Error"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
        }
        .onAppear { // should be called only once after the app start
            guard appState.snap.delayedTimer.not else { return }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if appState.settings.snapAfterAppStart {
                    appState.guide.ontheflyDetectionTapped()
                }
                appState.snap.delayedTimer = true
            }
            
            if appState.settings.keepSlideShowActive {
                activeSheet = .slideshow
            }
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
