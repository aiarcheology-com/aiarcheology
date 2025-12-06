//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import Combine
import OSLog


private enum ActiveSheet: Identifiable {
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
    // drawer:
    @State private var drawer = DrawerManager()
    // sheets, alerts and menus:
    @State private var showErrorAlert = false
    @State private var addressBarMenu: [URL] = []
    @State private var errorMessage = ""
    // content manipulation:
    @State private var brightness = SnapAdjustment.defaultBrightness
    @State private var contrast = SnapAdjustment.defaultContrast
    @State private var saturation = SnapAdjustment.defaultSaturation
    @State private var showSnapAdjustment = false
    @State private var activeSheet: ActiveSheet?
    
    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }
    
    var body: some View {
        DrawerContainer(manager: drawer) {
            mainContent
        } menu: {
            DrawerContent()
                .environment(drawer)
                .environmentObject(appState.deep)
                .environmentObject(appState.downloader)
        }
        .environment(drawer)
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .onReceive(appState.guide.$presentSettings) { present in
            activeSheet = present ? .settings : nil
        }
        .onReceive(appState.guide.$showSnapAdjustment) { show in
            // Bridge from Guide's showSnapAdjustment to local state for proper observation
            showSnapAdjustment = show
        }
        .onChange(of: showSnapAdjustment) { _, newValue in
            // Sync back to Guide when local state changes (e.g., overlay dismissed)
            guard appState.guide.showSnapAdjustment != newValue else { return }
            appState.guide.showSnapAdjustment = newValue
        }
        .onReceive(appState.guide.$presentedSideMenu) { shouldOpen in
            // Bridge from Guide's presentedSideMenu to new DrawerManager
            // Guard against sync loops
            guard shouldOpen != drawer.isOpen else { return }
            if shouldOpen {
                drawer.open()
            } else {
                drawer.close()
            }
        }
        .onChange(of: drawer.isOpen) { _, isOpen in
            // Sync drawer state back to Guide for any dependent code
            // Guard against sync loops
            guard appState.guide.presentedSideMenu != isOpen else { return }
            appState.guide.presentedSideMenu = isOpen
        }
        .onReceive(appState.deep.deepStateErrorPublisher) { error in
            guard let error else { return }
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(title: Text("Error"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            handleOnAppear()
        }
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
                ForEach(AppMode.tabOrder) { mode in
                    ViewContainer({
                        Screens.content(mode)
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
            
            // Address bar dropdown menu
            addressBarDropdown
        }
        // Snap adjustment overlay for iPhone (compact width)
        // On iPad/Mac, this is handled via popover in GlobalToolbarTrailing
        .snapAdjustmentOverlay(
            isPresented: $showSnapAdjustment,
            snapAdjustment: appState.snapAdjustment
        )
    }
    
    // MARK: - Address Bar Dropdown
    
    private var addressBarDropdown: some View {
        Color.clear
            .onReceive(appState.guide.$addressBarMenu) { urls in
                addressBarMenu = urls
            }
            .dropDownMenu(
                items: addressBarMenu,
                backgroundColor: colorScheme == .dark ? .black : .white,
                cancelContent: {
                    HStack {
                        Spacer()
                        Button {
                            appState.guide.addressBarMenu = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .testability(Testability.Button.contentViewAddressBarCancel)
                        .foregroundColor(.gray)
                        .padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 25))
                    }
                },
                itemContent: { item in
                    Button {
                        appState.guide.historySelected(item)
                    } label: {
                        Text(item.absoluteString.trimmedString)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .testability(Testability.Button.contentViewAddressBarHistoryItem)
                }
            )
    }
    
    // MARK: - Sheets
    
    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .slideshow:
            SlideshowView()
                .centerInParentView()
                .environmentObject(appState.settings)
            
        case .settings:
            SettingsForm()
                .environmentObject(appState.settings)
                .environmentObject(appState.guide)
        }
    }
    
    // MARK: - Lifecycle
    
    private func handleOnAppear() {
        // Should be called only once after the app start
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


// MARK: - Preview

#Preview {
    ContentView()
}
