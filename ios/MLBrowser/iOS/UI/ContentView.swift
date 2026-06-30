//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import Combine
import OSLog

struct ContentView: View {
    // environment:
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
                .environment(appState.tour)
                .environmentObject(appState.guide)
                .environmentObject(appState.deep)
                .environmentObject(appState.downloader)
                .environmentObject(appState.settings)
                .environmentObject(appState.subscriptionState)
        }
        .environment(drawer)
        // The single root attachment of the onboarding tour overlay (AIA-0333). Inert while
        // the tour is inactive.
        .tourOverlay(appState.tour)
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
            // Tour hook (AIA-0333): detection starting fulfills the PLAY step → reveal Next.
            appState.tour.evaluate()
        }
        .onReceive(appState.guide.$findModeRequested) { requested in
            // Tour hook (AIA-0333): `findModeRequested` is a transient pulse (reset to false by
            // WebScreen), so act on the pulse value rather than polling it later.
            if requested { appState.tour.pickModeDidStart() }
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
            // Tour hook (AIA-0333): re-evaluate the active step on any drawer change. In this
            // slice only the user opens the drawer, so advancing the `.drawerOpened` step
            // regardless of initiator is correct.
            appState.tour.evaluate()
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
        // UI-test introspection (inert outside UI tests).
        .checkpoint(.horizontalSizeClass, value: horizontalSizeClass == .regular ? "regular" : "compact")
        .checkpoint(.fullscreenFeatureEnabled, value: fullscreenFeatureEnabled ? "true" : "false")
        .checkpoint(.appMode, value: selectedMode == .web ? "web" : "gallery")
        .checkpoint(.deviceIdiom, value: HostPlatform.current.isiPhone ? "phone" : "pad")
    }
    
    // MARK: - Main Content

    /// Fullscreen = detection running with chrome hidden, on the web tab only. Suppressed while
    /// the onboarding tour is active so the toolbar (PLAY / Find) stays visible (AIA-0333); the
    /// user's `fullscreenDetection` setting is untouched.
    private var fullscreenActive: Bool {
        detectionEnabled && chromeVisible.not && selectedMode == .web && appState.tour.isActive.not
    }

    /// Safari-like adaptive address bar (AIA-0338): the address moves to the bottom only on
    /// iPhone in portrait (`verticalSizeClass == .regular`), on the web tab, in normal mode
    /// (chrome visible). iPad/Mac and iPhone landscape (`.compact`, incl. Plus/Max) keep the
    /// top bar. Computed once here and pushed into the environment so WebScreen's top/bottom
    /// gates and the floating-control reserve all derive from the same value.
    private var showsBottomAddressBar: Bool {
        FeatureFlags.isBottomAddressBarEnabled
            && HostPlatform.current.isiPhone
            && verticalSizeClass == .regular
            && selectedMode == .web
            && chromeVisible
    }

    private var mainContent: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
                ForEach(AppMode.tabOrder) { mode in
                    modeTab(mode)
                }
                .toolbar(AppMode.tabOrder.count == 1 ? .hidden : .visible, for: .tabBar)
            }

            floatingNavBar
            floatingChromeButton
        }
        // One source of truth for the adaptive address bar placement (AIA-0338): WebScreen
        // reads this to pick the top vs. bottom slot; the floating controls read the same
        // condition for their reserve. Injected here so both can never disagree on rotation.
        .environment(\.bottomAddressBarActive, showsBottomAddressBar)
        .statusBarHidden(fullscreenActive)
        // Snap adjustment overlay for iPhone (compact width)
        // On iPad/Mac, this is handled via popover in GlobalToolbarTrailing
        .snapAdjustmentOverlay(
            isPresented: $showSnapAdjustment,
            snapAdjustment: appState.snapAdjustment
        )
    }

    private func modeTab(_ mode: AppMode) -> some View {
        // Fullscreen detection for this tab: detection running, chrome hidden, web tab, no tour.
        let fullscreen = detectionEnabled && chromeVisible.not && mode == .web && appState.tour.isActive.not
        return ViewContainer(
            barsHidden: fullscreen,
            // Only iPhone reserves enough safe area to leave visible blank margins around the
            // map in fullscreen; iPad/Mac are unaffected and keep their default layout (AIA-0336).
            contentIgnoresSafeArea: fullscreen && HostPlatform.current.isiPhone,
            {
                modeScreen(mode)
            },
            leadingItems: {
                Screens.barItems(mode, position: .leading)
                    .environmentObject(appState.guide)
                    .environmentObject(appState.downloader)
            },
            trailingItems: {
                Screens.barItems(mode, position: .trailing)
                    .environmentObject(appState.guide)
            }
        )
        .tabItem {
            Screens.tabItem(mode, selection: appState.guide.mode)
        }
        .tag(mode)
    }

    private func modeScreen(_ mode: AppMode) -> some View {
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
    }

    // Floating back/reload/forward(/find) capsule. Unlike the rest of the chrome, it
    // stays visible in fullscreen — that's where it also carries Find (the top bar is gone).
    @ViewBuilder
    private var floatingNavBar: some View {
        if showsNavCapsule {
            FloatingNavBar(
                position: $floatingNavBarPosition,
                showsFind: fullscreenActive,
                onFind: {
                    appState.guide.findTapped()
                },
                // Keep the capsule above the bottom address bar when it's shown (AIA-0338).
                bottomReserve: showsBottomAddressBar ? BottomAddressBarMetrics.reserve : 0
            )
            .environmentObject(appState.browserState)
            .transition(.opacity)
        }
    }

    /// The navigation capsule shows on iPhone in normal mode (the top bar has no room for
    /// back/forward/reload there), and on *every* device in fullscreen, where the top bar —
    /// and its Find button — are hidden, so the capsule also carries Find. iPad/Mac keep
    /// navigation in the top bar in normal mode (AIA-0294).
    private var showsNavCapsule: Bool {
        guard selectedMode == .web else { return false }
        if fullscreenActive { return true }
        return HostPlatform.current.isiPhone && chromeVisible
    }

    // Chrome toggle for fullscreen detection mode; only its 52pt frame
    // is hit-testable, all other touches reach the web view.
    @ViewBuilder
    private var floatingChromeButton: some View {
        if detectionEnabled && fullscreenFeatureEnabled && selectedMode == .web && appState.tour.isActive.not {
            FloatingChromeButton(
                position: $floatingButtonPosition,
                // Keep the chrome toggle above the bottom address bar when it's shown (AIA-0338).
                bottomReserve: showsBottomAddressBar ? BottomAddressBarMetrics.reserve : 0
            )
                .environmentObject(appState.guide)
                .transition(.opacity)
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

        // Onboarding tour (AIA-0333): bind the live drawer. Under UI tests the tour starts
        // only when a test explicitly opts in via `startOnboardingTour`, so the overlay never
        // covers the chrome other tests assert against. In shipping, run the first-launch
        // gate/migration decision.
        // The production auto-start decision runs earlier, in `AppState.initialize()`, so the
        // onboarding demo page is staged before this view appears. Here we only bind the live
        // drawer and honor the UI-test launch flag.
        appState.tour.bind(drawer: drawer, guide: appState.guide)
        if AppEnvironment.isRunningUITests, UITestLaunchConfiguration.shouldStartOnboardingTour {
            appState.tour.start()
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
