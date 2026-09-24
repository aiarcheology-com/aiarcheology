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
        AID.settingsDisableDetectionAnimations,
        AID.settingsTiledDetection,
        AID.settingsFullscreenDetection,
        AID.settingsDefaultPage,
        AID.settingsReopenLastPage,
        AID.settingsHistory,
        AID.settingsHistoryLimit,
        AID.settingsDeleteCache,
        AID.settingsAbout,
        AID.settingsReplayOnboarding,
        AID.settingsReset
    ]

    /// Remove Findings and Restore Defaults now live behind the "Reset" entry in the ML Browser
    /// section — navigate into that submenu before asserting either action.
    private func openResetSubmenu() {
        XCTAssertTrue(scrollTo(AID.settingsReset), "Reset row missing from ML Browser section")
        element(AID.settingsReset).tap()
    }

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

    func testSettings_toggleDisableDetectionAnimations_flipsState() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsDisableDetectionAnimations), "Disable-detection-animations toggle missing")
        XCTAssertTrue(flipSwitch(AID.settingsDisableDetectionAnimations), "Disable-detection-animations toggle did not change state")
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

    func testSettings_reportProblemSubmenu_showsEmailAndScreenshotControls() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsAbout))
        element(AID.settingsAbout).tap()
        XCTAssertTrue(
            element(AID.appDescriptionReportProblem).waitForExistence(timeout: 10),
            "Report-a-problem settings entry missing"
        )
        element(AID.appDescriptionReportProblem).tap()
        XCTAssertTrue(
            element(AID.supportSettingsSendEmail).waitForExistence(timeout: 10),
            "Send-email action missing from the report-a-problem submenu"
        )
        XCTAssertTrue(
            element(AID.supportSettingsDetectScreenshots).waitForExistence(timeout: 10),
            "Screenshot-detection toggle missing from the report-a-problem submenu"
        )
        XCTAssertTrue(
            flipSwitch(AID.supportSettingsDetectScreenshots),
            "Screenshot-detection toggle did not change state"
        )
        element(AID.supportSettingsSendEmail).tap()
        XCTAssertTrue(
            element(AID.supportRequestIncludeApplicationLog).waitForExistence(timeout: 10),
            "Application-log toggle missing from the support email form"
        )
        XCTAssertEqual(
            element(AID.supportRequestIncludeApplicationLog).value as? String,
            "0",
            "Application-log inclusion should be off by default"
        )
        XCTAssertTrue(
            element(AID.supportRequestSendUnredactedData).waitForExistence(timeout: 10),
            "Unredacted-data toggle missing from the support email form"
        )
        XCTAssertFalse(
            element(AID.supportRequestSendUnredactedData).isEnabled,
            "Unredacted data must require application-log inclusion"
        )
        XCTAssertTrue(
            flipSwitch(AID.supportRequestIncludeApplicationLog),
            "Application-log toggle did not change state"
        )
        XCTAssertTrue(element(AID.supportRequestSendUnredactedData).isEnabled)
        XCTAssertEqual(
            element(AID.supportRequestSendUnredactedData).value as? String,
            "0",
            "Unredacted data should be off by default"
        )
        XCTAssertTrue(
            flipSwitch(AID.supportRequestSendUnredactedData),
            "Unredacted-data toggle did not change state"
        )
        XCTAssertTrue(
            flipSwitch(AID.supportRequestIncludeApplicationLog),
            "Application-log toggle did not turn off"
        )
        XCTAssertFalse(element(AID.supportRequestSendUnredactedData).isEnabled)
        XCTAssertEqual(
            element(AID.supportRequestSendUnredactedData).value as? String,
            "0",
            "Turning off application-log inclusion must clear raw-data consent"
        )
        XCTAssertTrue(
            flipSwitch(AID.supportRequestIncludeApplicationLog),
            "Application-log toggle did not turn back on"
        )
        XCTAssertTrue(element(AID.supportRequestSendUnredactedData).isEnabled)
        XCTAssertEqual(
            element(AID.supportRequestSendUnredactedData).value as? String,
            "0",
            "Raw-data consent must remain off after re-enabling application-log inclusion"
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
        // UI tests pin the locale to en_US, where the previous screen title is the back button's title.
        let back = tiledDetectionNavigationBar.buttons["Settings"]
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

    func testSettings_resetSubmenu_showsRemoveAndRestore() {
        launch()
        openSettings()
        openResetSubmenu()
        XCTAssertTrue(
            element(AID.settingsRemoveFindings).waitForExistence(timeout: 10),
            "Remove Findings action missing from the Reset submenu"
        )
        XCTAssertTrue(
            element(AID.settingsRestoreDefaults).waitForExistence(timeout: 10),
            "Restore Defaults action missing from the Reset submenu"
        )
    }

    func testSettings_restoreDefaults_showsConfirmation() {
        launch()
        openSettings()
        openResetSubmenu()
        XCTAssertTrue(scrollTo(AID.settingsRestoreDefaults))
        element(AID.settingsRestoreDefaults).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Restore-defaults confirmation not shown")
    }

    /// AIA-0303: tapping Remove Findings shows the confirmation alert, and Cancel dismisses it
    /// without deleting. This is a WIRING check only — the delete BEHAVIOR (rows + screenshots gone)
    /// is proven by the disk-backed `RemoveAllFindingsTests`, because the UI-test app seeds no
    /// findings, so an in-UI "nothing was deleted" assertion would be vacuous. The Delete action is
    /// matched by its testability id, NOT its text: `.testability` overrides the accessibility LABEL
    /// with the id under UI_TESTING, so a text query ("Delete All Findings") would never match.
    func testSettings_removeFindings_cancelDismissesWithoutDeleting() {
        launch()
        openSettings()
        openResetSubmenu()
        XCTAssertTrue(scrollTo(AID.settingsRemoveFindings), "Remove Findings row missing")
        element(AID.settingsRemoveFindings).tap()

        let deleteAction = app.buttons[AID.settingsRemoveFindingsConfirm]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Remove Findings confirmation not shown")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: deleteAction), "Confirmation should dismiss after Cancel")
    }

    /// AIA-0331: Delete cache asks first, and Cancel dismisses the alert. Wiring only — the wipe
    /// itself (`WebCacheCleaner.clean()`) has no UI-observable effect to assert on.
    func testSettings_deleteCache_cancelDismissesConfirmation() {
        launch()
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsDeleteCache), "Delete cache row missing")
        element(AID.settingsDeleteCache).tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete-cache confirmation not shown")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: alert), "Confirmation should dismiss after Cancel")
    }

    func testSettings_dismiss() {
        launch()
        openSettings()
        let dismiss = app.buttons[AID.settingsDismiss]
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: dismiss), "Settings sheet did not dismiss")
    }
}
