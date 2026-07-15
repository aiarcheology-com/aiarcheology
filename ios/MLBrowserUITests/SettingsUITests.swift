//
//  SettingsUITests.swift
//  MLBrowserUITests
//
//  AIA-0305: settings-screen coverage. Verifies the full set of options is present, a toggle
//  flips, every submenu (About / Introduction / History) is reachable and shows its content,
//  restore-defaults confirms, and the sheet dismisses. All network-free.
//

import XCTest

final class SettingsUITests: UITestCase {

    /// Every option the settings form is expected to expose, top to bottom.
    private let expectedOptions = [
        AID.settingsFrequency,
        AID.settingsRunAtLaunch,
        AID.settingsShowLabels,
        AID.settingsTiledDetection,
        AID.settingsFullscreenDetection,
        AID.settingsDefaultPage,
        AID.settingsReopenLastPage,
        AID.settingsHistory,
        AID.settingsHistoryLimit,
        AID.settingsDeleteCache,
        AID.settingsAbout,
        AID.settingsReplayOnboarding,
        AID.settingsRestoreDefaults
    ]

    func testSettings_allOptionsPresent() {
        launch()
        openSettings()
        // Options span more than one screen; scroll toward each in declaration order.
        for id in expectedOptions {
            XCTAssertTrue(scrollTo(id), "Settings option missing: \(id)")
        }
    }

    func testSettings_toggleShowLabels_flipsState() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsShowLabels), "Show-labels toggle missing")
        XCTAssertTrue(flipSwitch(AID.settingsShowLabels), "Show-labels toggle did not change state")
    }

    func testSettings_toggleFullscreenDetection_flipsState() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsFullscreenDetection), "Fullscreen-detection toggle missing")
        XCTAssertTrue(flipSwitch(AID.settingsFullscreenDetection), "Fullscreen-detection toggle did not change state")
    }

    func testSettings_aboutSubmenu_showsContent() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsAbout))
        element(AID.settingsAbout).tap()
        // AppDescriptionView exposes the privacy-policy navigation link.
        XCTAssertTrue(
            element("_AIA:NavigationLink.AppDescriptionPrivacyPolicy").waitForExistence(timeout: 10),
            "About submenu content not shown"
        )
    }

    func testSettings_replayOnboarding_startsTour() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsReplayOnboarding))
        // The "Replay onboarding" row dismisses Settings + drawer and starts the tour
        // (AIA-0333); its first bubble appears over the address bar.
        element(AID.settingsReplayOnboarding).tap()
        XCTAssertTrue(
            element(AID.tourBubble).waitForExistence(timeout: 10),
            "Replaying onboarding should start the tour"
        )
    }

    func testSettings_historySubmenu_showsList() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsHistory))
        element(AID.settingsHistory).tap()
        XCTAssertTrue(
            app.buttons[AID.historyClear].waitForExistence(timeout: 10),
            "History submenu not shown"
        )
    }

    func testSettings_tiledDetectionSubmenu_showsSchemeToggles() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsTiledDetection), "Tiled Detection row missing")
        element(AID.settingsTiledDetection).tap()
        XCTAssertTrue(
            element(AID.settingsPyramidTiling).waitForExistence(timeout: 10),
            "Pyramid tiling toggle not shown in Tiled Detection submenu"
        )
        XCTAssertTrue(
            element(AID.settingsGrid3x3Tiling).waitForExistence(timeout: 10),
            "3x3 tiling toggle not shown in Tiled Detection submenu"
        )
        XCTAssertTrue(
            element(AID.settingsTiledBorders).waitForExistence(timeout: 10),
            "Tiled Borders toggle not shown in Tiled Detection submenu"
        )
        // Confirm a scheme toggle is actually interactive, not just present.
        XCTAssertTrue(flipSwitch(AID.settingsPyramidTiling), "Pyramid tiling toggle did not change state")
    }

    /// Regression guard (AIA-0426): enabling Tiled Borders in the submenu must actually render the
    /// tile-outline overlay on the web view — not merely flip a switch. Reads the in-app
    /// `tiledBorderCount` checkpoint (0 when off; `regions(for:)` count when on).
    func testTiledBorders_enablingInSubmenu_rendersOverlay() {
        launch()
        // Off by default → the overlay draws nothing.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpTiledBorderCount, equals: "0"),
            "Tile borders should not render while the setting is off"
        )
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsTiledDetection), "Tiled Detection row missing")
        element(AID.settingsTiledDetection).tap()
        XCTAssertTrue(flipSwitch(AID.settingsTiledBorders), "Tiled Borders toggle did not flip on")
        // Return to the web screen (pop the submenu, dismiss Settings) where the overlay lives.
        // Scope the tap to the presented submenu. A global navigation-bar query can select a
        // browser control behind the Settings sheet on CI, leaving the submenu on screen.
        let tiledDetectionNavigationBar = app.navigationBars["Tiled Detection"]
        XCTAssertTrue(tiledDetectionNavigationBar.waitForExistence(timeout: 5), "Tiled Detection navigation bar missing")
        let back = tiledDetectionNavigationBar.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Settings back button missing in Tiled Detection submenu")
        back.tap()
        let dismiss = app.buttons[AID.settingsDismiss]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Settings dismiss button missing after pop")
        dismiss.tap()
        // Pyramid tiling is on by default (6 regions — see DetectionTilingTests), so enabling
        // Tiled Borders renders 6 tile outlines over the web view.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpTiledBorderCount, equals: "6"),
            "Enabling Tiled Borders should render the pyramid tile outlines over the web view"
        )
    }

    func testSettings_restoreDefaults_showsConfirmation() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsRestoreDefaults))
        element(AID.settingsRestoreDefaults).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Restore-defaults confirmation not shown")
    }

    func testSettings_dismiss() {
        launch()
        openSettings()
        let dismiss = app.buttons[AID.settingsDismiss]
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: dismiss), "Settings sheet did not dismiss")
    }
}
