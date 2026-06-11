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
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // app model:
    @EnvironmentObject var appState: AppState
    // drawer:
    @State private var drawer = DrawerManager()
    // sheets, alerts and menus:
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    // content manipulation:
    @State private var brightness = SnapAdjustment.defaultBrightness
    @State private var contrast = SnapAdjustment.defaultContrast
    @State private var saturation = SnapAdjustment.defaultSaturation
    @State private var showSnapAdjustment = false
    @State private var activeSheet: ActiveSheet?
    // Fullscreen detection mode (one-way bridges from Guide; the view only reads):
    @State private var detectionEnabled = false
    @State private var chromeVisible = true
    @State private var fullscreenFeatureEnabled = true
    @State private var selectedMode = AppMode.web
    @State private var floatingButtonPosition: CGPoint?
    @State private var floatingNavBarPosition: CGPoint?
    
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
                .environmentObject(appState.guide)
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
        .onReceive(appState.guide.$ontheflyDetectionEnabled) { enabled in
            withAnimation { detectionEnabled = enabled }
        }
        .onReceive(appState.guide.$chromeVisible) { visible in
            withAnimation { chromeVisible = visible }
        }
        .onReceive(appState.settings.$fullscreenDetection) { enabled in
            withAnimation { fullscreenFeatureEnabled = enabled }
        }
        .onReceive(appState.guide.$mode) { mode in
            selectedMode = mode
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
            Alert(title: Text(L10n.Alert.Error.title), message: Text(errorMessage), dismissButton: .default(Text(L10n.Common.ok)))
        }
        .onAppear {
            handleOnAppear()
        }
    }
    
    // MARK: - Main Content

    /// Fullscreen = detection running with chrome hidden, on the web tab only.
    private var fullscreenActive: Bool {
        detectionEnabled && chromeVisible.not && selectedMode == .web
    }

    private var mainContent: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
                ForEach(AppMode.tabOrder) { mode in
                    ViewContainer(barsHidden: detectionEnabled && chromeVisible.not && mode == .web, {
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
                            .environmentObject(appState.browserState)
                    })
                    .tabItem {
                        Screens.tabItem(mode, selection: appState.guide.mode)
                    }
                    .tag(mode)
                }
                .toolbar(AppMode.tabOrder.count == 1 ? .hidden : .visible, for: .tabBar)
            }
            
            // Floating back/reload/forward capsule for compact widths — part of the
            // chrome, so fullscreen detection hides it together with the bars.
            if selectedMode == .web && horizontalSizeClass == .compact && chromeVisible {
                FloatingNavBar(position: $floatingNavBarPosition)
                    .environmentObject(appState.browserState)
                    .transition(.opacity)
            }

            // Chrome toggle for fullscreen detection mode; only its 52pt frame
            // is hit-testable, all other touches reach the web view.
            if detectionEnabled && fullscreenFeatureEnabled && selectedMode == .web {
                FloatingChromeButton(position: $floatingButtonPosition)
                    .environmentObject(appState.guide)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(fullscreenActive)
        // Snap adjustment overlay for iPhone (compact width)
        // On iPad/Mac, this is handled via popover in GlobalToolbarTrailing
        .snapAdjustmentOverlay(
            isPresented: $showSnapAdjustment,
            snapAdjustment: appState.snapAdjustment
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
