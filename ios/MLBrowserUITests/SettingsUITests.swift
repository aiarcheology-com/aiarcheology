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
        AID.settingsIntroduction,
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
        XCTAssertTrue(scrollTo(AID.settingsIntroduction))
        // The "Replay onboarding" row dismisses Settings + drawer and starts the tour
        // (AIA-0333); its first bubble appears over the address bar.
        element(AID.settingsIntroduction).tap()
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
