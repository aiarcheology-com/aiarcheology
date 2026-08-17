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
    // Fullscreen detection mode (one-way bridges from detectionState/settings; the view only reads):
    @State private var detectionEnabled = false
    @State private var chromeVisible = true
    @State private var fullscreenFeatureEnabled = true
    @State private var selectedMode = AppMode.web
    @State private var floatingButtonPosition: CGPoint?
    @State private var floatingNavBarPosition: CGPoint?
    /// The shared finding link waiting to be shown (AIA-0650), mirrored from `SharedFindingState`.
    @State private var pendingSharedFinding: FindingShareLink.Payload?
    
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
                .environmentObject(appState.chromeState)
                .environmentObject(appState.detectionState)
                .environmentObject(appState.deep)
                .environmentObject(appState.downloader)
                .environmentObject(appState.settings)
                .environmentObject(appState.subscriptionState)
				.environmentObject(appState.analytics)
                // Observed, not reached through `appState` (AIA-0536): a nested ObservableObject
                // does not republish through its parent, so the drawer's sign-in row would go stale
                // the moment the session changed under it. Before the cut-over a sign-out unmounted
                // the whole tree, so nothing here ever had to notice.
                .environmentObject(appState.authState)
        }
        .environment(drawer)
        // The single root attachment of the onboarding tour overlay (AIA-0333). Inert while
        // the tour is inactive.
        .tourOverlay(appState.tour)
        .onReceive(appState.detectionState.$showSnapAdjustment) { show in
            // Bridge from detectionState's showSnapAdjustment to local state for proper observation
            showSnapAdjustment = show
        }
        .onChange(of: showSnapAdjustment) { _, newValue in
            // Sync back to detectionState when local state changes (e.g., overlay dismissed)
            guard appState.detectionState.showSnapAdjustment != newValue else { return }
            appState.detectionState.showSnapAdjustment = newValue
        }
        .onReceive(appState.detectionState.$ontheflyDetectionEnabled) { enabled in
            withAnimation { detectionEnabled = enabled }
            // Tour hook (AIA-0333): detection starting fulfills the PLAY step → reveal Next.
            appState.tour.evaluate()
        }
        .onReceive(appState.chromeState.$findModeRequested) { requested in
            // Tour hook (AIA-0333): `findModeRequested` is a transient pulse (reset to false by
            // WebScreen), so act on the pulse value rather than polling it later.
            if requested { appState.tour.pickModeDidStart() }
        }
        .onReceive(appState.detectionState.$chromeVisible) { visible in
            withAnimation { chromeVisible = visible }
        }
        .onReceive(appState.settings.$fullscreenDetection) { enabled in
            withAnimation { fullscreenFeatureEnabled = enabled }
        }
        .onReceive(appState.chromeState.$mode) { mode in
            selectedMode = mode
        }
        .onReceive(appState.chromeState.$presentedSideMenu) { shouldOpen in
            // Bridge from chromeState's presentedSideMenu to new DrawerManager
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
            // Sync drawer state back to chromeState for any dependent code
            // Guard against sync loops
            guard appState.chromeState.presentedSideMenu != isOpen else { return }
            appState.chromeState.presentedSideMenu = isOpen
        }
        .onReceive(appState.deep.deepStateErrorPublisher) { error in
            guard let error else { return }
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(title: Text(L10n.Alert.Error.title), message: Text(errorMessage), dismissButton: .default(Text(L10n.Common.ok)))
        }
        // A shared finding link (AIA-0650). Attached here so it sits above the app content but
        // *inside* the subscription and analytics gates — a link must never be a way past either.
        //
        // An **overlay**, deliberately not a sheet, for the reason `AnalyticsChoiceGate` documents
        // at length: this is an ancestor of every sheet the app presents, and a sheet raised from an
        // ancestor while a descendant's sheet is up presents and then immediately auto-dismisses. A
        // link can arrive while Settings or the findings list is open, which is exactly that case.
        //
        // The pending link is cleared **only** by `SharedFindingState.dismiss()`, from a control the
        // user pressed inside the screen — never here, and never on a presentation that did not
        // happen. While a sheet covers the app the link waits behind it, the same deliberate
        // trade-off the consent gate makes.
        //
        // Bridged through `@State` rather than read off `appState`: `sharedFinding` is a nested
        // `ObservableObject` and does not republish through its parent, so a link arriving would
        // never redraw this body. Same pattern as the chrome/detection bridges above.
        .onReceive(appState.sharedFinding.$pending) { payload in
            pendingSharedFinding = payload
        }
        .overlay {
            if let payload = pendingSharedFinding {
                SharedFindingView(payload: payload)
                    .environmentObject(appState)
                    .transition(.opacity)
            }
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
        HostPlatform.current.isiPhone
            && verticalSizeClass == .regular
            && selectedMode == .web
            && chromeVisible
    }

    private var mainContent: some View {
        ZStack {
            // Bind through an explicit `Binding` on the chrome state object (AIA-0391).
            TabView(selection: Binding(get: { appState.chromeState.mode }, set: { appState.chromeState.mode = $0 })) {
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
                    .environmentObject(appState.chromeState)
                    .environmentObject(appState.detectionState)
                    .environmentObject(appState.downloader)
            },
            trailingItems: {
                Screens.barItems(mode, position: .trailing)
                    .environmentObject(appState.chromeState)
                    .environmentObject(appState.detectionState)
            }
        )
        .tabItem {
            Screens.tabItem(mode, selection: appState.chromeState.mode)
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
                    appState.chromeState.findTapped()
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
                .environmentObject(appState.chromeState)
                .environmentObject(appState.detectionState)
                .transition(.opacity)
        }
    }
    
    // MARK: - Lifecycle

    private func handleOnAppear() {
        // Should be called only once after the app start
        guard appState.snap.delayedTimer.not else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // Not while onboarding still owes the user a turn (AIA-0567). This content is now
            // mounted *underneath* the day-0 Welcome screen, where it never used to be — so without
            // this guard detection would start behind a screen the user is still reading, and then
            // be stopped again by `TourState.start()`'s reset the moment they tapped Continue. The
            // user would see a detection run they never asked for, bracketed by nothing.
            if appState.settings.snapAfterAppStart, appState.tour.isPendingOrRunning.not {
                appState.detectionState.ontheflyDetectionTapped()
            }
            appState.snap.delayedTimer = true
        }

        // Onboarding tour (AIA-0333): bind the live drawer, and nothing else.
        //
        // This used to start the tour on the UI-test path. It cannot any more (AIA-0567): both the
        // production and the UI-test arming decisions run in `AppState.initialize()`, and
        // `SubscriptionGateView` starts what they armed. Starting here as well would race that —
        // and starting here *instead* would be worse, since this runs after the gate's
        // `onChange(initial: true)` handlers, so the tests would cover a path the app never takes.
        appState.tour.bind(drawer: drawer, chromeState: appState.chromeState, detectionState: appState.detectionState)
    }
}

#if DEBUG
// MARK: - Preview

#Preview {
    ContentView()
}
#endif
