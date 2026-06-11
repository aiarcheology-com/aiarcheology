//
//  GuideTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

/// Creates a DataController with a temporary SQLite store for tests that require
/// NSBatchDeleteRequest to work (which doesn't work with in-memory stores).
@MainActor
func createTempSQLiteDataController() -> (DataController, URL) {
    let tempDir = FileManager.default.temporaryDirectory
    let storeURL = tempDir.appendingPathComponent("TestStore-\(UUID().uuidString).sqlite")
    let dataController = DataController(storeURL: storeURL)
    return (dataController, storeURL)
}

@MainActor
final class GuideTests: XCTestCase {

    var settings: Settings!
    var snapState: SnapState!
    var deepState: DeepState!
    var snapAdjustment: SnapAdjustment!
    var dataController: DataController!
    var demoDataManager: DemoDataManager!
    var sut: Guide!
    private var tempStoreURL: URL?

    override func setUp() async throws {
        try await super.setUp()

        settings = Settings()
        // Settings persists to UserDefaults.standard; pin the default so tests
        // that flip the flag cannot leak into later tests via the suite's defaults.
        settings.fullscreenDetection = true
        dataController = DataController(inMemory: true)
        snapState = SnapState(settings: settings)
        deepState = DeepState(dataController: dataController)
        snapAdjustment = SnapAdjustment()
        demoDataManager = DemoDataManager(dataController: dataController)

        sut = Guide(
            snap: snapState,
            deep: deepState,
            settings: settings,
            dataController: dataController,
            demoDataManager: demoDataManager,
            snapAdjustment: snapAdjustment
        )
    }

    override func tearDown() async throws {
        snapState.stopTimer()
        sut = nil
        demoDataManager = nil
        dataController = nil
        snapAdjustment = nil
        deepState = nil
        snapState = nil
        settings = nil

        // Clean up temporary SQLite store if used
        if let url = tempStoreURL {
            try? FileManager.default.removeItem(at: url)
            // Also remove -wal and -shm files
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
            tempStoreURL = nil
        }

        try await super.tearDown()
    }

    /// Sets up the test with a temporary SQLite store instead of in-memory.
    /// Use this for tests that call resetApplication() or other batch delete operations.
    private func setUpWithSQLiteStore() async {
        // Unload the in-memory store before creating the SQLite store to avoid conflicts.
        // Note: In test environments, store removal failures are typically non-critical
        // as the old store will be discarded when dataController is replaced.
        for store in dataController.container.persistentStoreCoordinator.persistentStores {
            do {
                try dataController.container.persistentStoreCoordinator.remove(store)
            } catch {
                // Log but continue - the old in-memory store will be discarded anyway
                print("Warning: Failed to remove in-memory store during test setup: \(error)")
            }
        }

        let (sqliteController, storeURL) = createTempSQLiteDataController()
        tempStoreURL = storeURL
        dataController = sqliteController
        await dataController.awaitStoreReady()

        deepState = DeepState(dataController: dataController)
        demoDataManager = DemoDataManager(dataController: dataController)

        sut = Guide(
            snap: snapState,
            deep: deepState,
            settings: settings,
            dataController: dataController,
            demoDataManager: demoDataManager,
            snapAdjustment: snapAdjustment
        )
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        XCTAssertNotNil(sut.snap)
        XCTAssertNotNil(sut.deep)
        XCTAssertNotNil(sut.settings)
        XCTAssertNotNil(sut.dataController)
        XCTAssertNotNil(sut.demoDataManager)
        XCTAssertNotNil(sut.snapAdjustment)
    }
    
    func testInitialState() {
        XCTAssertEqual(sut.mode, .web)
        XCTAssertFalse(sut.presentedSideMenu)
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(sut.selectedConfigurationId)
        XCTAssertFalse(sut.presentSettings)
        XCTAssertNil(sut.pageToOpen)
        XCTAssertTrue(sut.addressBarMenu.isEmpty)
        XCTAssertNil(sut.addressSelected)
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }
    
    // MARK: - Side Menu Tests
    
    func testTogglingSideMenu_TogglesState() {
        XCTAssertFalse(sut.presentedSideMenu)
        
        sut.togglingSideMenu()
        
        XCTAssertTrue(sut.presentedSideMenu)
    }
    
    func testTogglingSideMenu_TogglesBackToFalse() {
        sut.presentedSideMenu = true
        
        sut.togglingSideMenu()
        
        XCTAssertFalse(sut.presentedSideMenu)
    }
    
    func testTogglingSideMenu_MultipleToggles() {
        XCTAssertFalse(sut.presentedSideMenu)
        
        sut.togglingSideMenu()
        XCTAssertTrue(sut.presentedSideMenu)
        
        sut.togglingSideMenu()
        XCTAssertFalse(sut.presentedSideMenu)
        
        sut.togglingSideMenu()
        XCTAssertTrue(sut.presentedSideMenu)
    }
    
    // MARK: - Settings Tests
    
    func testSettingsTapped_ShowsSettings() {
        XCTAssertFalse(sut.presentSettings)
        
        sut.settingsTapped()
        
        XCTAssertTrue(sut.presentSettings)
    }
    
    func testSettingsTapped_CalledTwice_StaysTrue() {
        sut.settingsTapped()
        sut.settingsTapped()
        
        XCTAssertTrue(sut.presentSettings)
    }
    
    // MARK: - History Selection Tests
    
    func testHistorySelected_SetsAddressSelected() {
        let url = URL(string: "https://example.com")!
        
        sut.historySelected(url)
        
        XCTAssertEqual(sut.addressSelected, url)
    }
    
    func testHistorySelected_ClearsAddressBarMenu() {
        sut.addressBarMenu = [
            URL(string: "https://one.com")!,
            URL(string: "https://two.com")!
        ]
        let url = URL(string: "https://example.com")!
        
        sut.historySelected(url)
        
        XCTAssertTrue(sut.addressBarMenu.isEmpty)
    }
    
    func testHistorySelected_UpdatesBothProperties() {
        sut.addressBarMenu = [URL(string: "https://old.com")!]
        let newUrl = URL(string: "https://new.com")!
        
        sut.historySelected(newUrl)
        
        XCTAssertEqual(sut.addressSelected, newUrl)
        XCTAssertTrue(sut.addressBarMenu.isEmpty)
    }
    
    // MARK: - On-the-fly Detection Tests
    
    func testOntheflyDetectionTapped_TogglesState() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        
        sut.ontheflyDetectionTapped()
        
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
    }
    
    func testOntheflyDetectionTapped_TogglesBackToFalse() {
        sut.ontheflyDetectionEnabled = true
        
        sut.ontheflyDetectionTapped()
        
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
    }
    
    func testOntheflyDetectionTapped_StartsTimer_WhenEnabled() {
        XCTAssertNil(snapState.timerCancellable)
        
        sut.ontheflyDetectionTapped()
        
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)
    }
    
    func testOntheflyDetectionTapped_StopsTimer_WhenDisabled() {
        // Enable first
        sut.ontheflyDetectionTapped()
        XCTAssertNotNil(snapState.timerCancellable)
        
        // Disable
        sut.ontheflyDetectionTapped()
        
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
    }
    
    // MARK: - Chrome Visibility Tests
    //
    // Uniform rule: every detection start hides chrome, every stop shows it,
    // regardless of initiator. Background/foreground auto-pause/resume and
    // snapAfterAppStart route through the same ontheflyDetectionTapped().

    func testOntheflyDetectionTapped_Start_HidesChrome() {
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
        XCTAssertTrue(sut.showsFloatingChromeButton)
    }

    func testOntheflyDetectionTapped_Stop_ShowsChrome() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }

    func testChromeToggleTapped_RevealsAndHidesChromeWhileDetecting() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertTrue(sut.ontheflyDetectionEnabled, "Revealing chrome must not stop detection")
        XCTAssertTrue(sut.showsFloatingChromeButton, "Floating button stays while detection runs")

        sut.chromeToggleTapped()
        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
    }

    func testOntheflyDetectionTapped_Stop_DismissesSnapAdjustment() {
        sut.ontheflyDetectionTapped()
        sut.showSnapAdjustment = true

        sut.ontheflyDetectionTapped()

        XCTAssertFalse(sut.showSnapAdjustment, "Stopping detection would orphan an open adjustment overlay")
    }

    func testOntheflyDetectionResetTapped_DoesNotTouchChrome() {
        sut.ontheflyDetectionTapped()
        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionResetTapped()

        XCTAssertTrue(sut.chromeVisible, "Timer restart must not change chrome state")
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
    }

    func testDetectionToggleSequence_BackgroundForegroundCycle_ReturnsToFullscreen() {
        // Simulates: detection on, user reveals chrome, app backgrounds (auto-pause),
        // app foregrounds (auto-resume). Uniform rule: resume re-enters fullscreen.
        sut.ontheflyDetectionTapped()
        sut.chromeToggleTapped()
        XCTAssertTrue(sut.chromeVisible)

        sut.ontheflyDetectionTapped() // background: auto-pause
        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.ontheflyDetectionEnabled)

        sut.ontheflyDetectionTapped() // foreground: auto-resume
        XCTAssertFalse(sut.chromeVisible, "Detection resume re-enters fullscreen (uniform rule)")
        XCTAssertTrue(sut.isFullscreen)
    }

    // MARK: - Fullscreen Detection Setting

    func testOntheflyDetectionTapped_Start_KeepsChrome_WhenFullscreenDetectionDisabled() {
        settings.fullscreenDetection = false

        sut.ontheflyDetectionTapped()

        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertTrue(sut.chromeVisible, "Disabled feature keeps the chrome visible during detection")
        XCTAssertFalse(sut.isFullscreen)
        XCTAssertFalse(sut.showsFloatingChromeButton, "No floating button when the feature is off")
    }

    func testFullscreenDetectionSettingChanged_DisablingMidDetection_RestoresChrome() {
        sut.ontheflyDetectionTapped()
        XCTAssertFalse(sut.chromeVisible)

        settings.fullscreenDetection = false
        sut.fullscreenDetectionSettingChanged()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertTrue(sut.ontheflyDetectionEnabled, "Changing the setting must not stop detection")
        XCTAssertFalse(sut.showsFloatingChromeButton)
    }

    func testFullscreenDetectionSettingChanged_EnablingMidDetection_EntersFullscreen() {
        settings.fullscreenDetection = false
        sut.ontheflyDetectionTapped()
        XCTAssertTrue(sut.chromeVisible)

        settings.fullscreenDetection = true
        sut.fullscreenDetectionSettingChanged()

        XCTAssertFalse(sut.chromeVisible)
        XCTAssertTrue(sut.isFullscreen)
    }

    func testFullscreenDetectionSettingChanged_WhileDetectionOff_IsNoOp() {
        settings.fullscreenDetection = false

        sut.fullscreenDetectionSettingChanged()

        XCTAssertTrue(sut.chromeVisible)
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
    }

    // MARK: - On-the-fly Detection Reset Tests

    func testOntheflyDetectionResetTapped_WhenEnabled_RestartsTimer() {
        sut.ontheflyDetectionEnabled = true
        snapState.startTimer()
        XCTAssertNotNil(snapState.timerCancellable)
        
        sut.ontheflyDetectionResetTapped()
        
        // Timer should be restarted (stop + start)
        XCTAssertNotNil(snapState.timerCancellable)
    }
    
    func testOntheflyDetectionResetTapped_WhenDisabled_DoesNothing() {
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
        
        sut.ontheflyDetectionResetTapped()
        
        // Should not start timer when detection is disabled
        XCTAssertNil(snapState.timerCancellable)
    }
    
    // MARK: - Mode Tests
    
    func testMode_CanBeChanged() {
        XCTAssertEqual(sut.mode, .web)
        
        sut.mode = .gallery
        
        XCTAssertEqual(sut.mode, .gallery)
    }
    
    // MARK: - Configuration Selection Tests
    
    func testSelectedConfigurationId_CanBeSet() {
        let id = UUID()
        
        sut.selectedConfigurationId = id
        
        XCTAssertEqual(sut.selectedConfigurationId, id)
    }
    
    func testSelectedConfigurationId_CanBeCleared() {
        sut.selectedConfigurationId = UUID()
        
        sut.selectedConfigurationId = nil
        
        XCTAssertNil(sut.selectedConfigurationId)
    }
    
    // MARK: - Page To Open Tests
    
    func testPageToOpen_CanBeSet() {
        let url = URL(string: "https://example.com")!
        
        sut.pageToOpen = url
        
        XCTAssertEqual(sut.pageToOpen, url)
    }
    
    // MARK: - Reset Application Tests
    // Note: All resetApplication tests use SQLite store because NSBatchDeleteRequest
    // (used by deep.reset()) doesn't work with in-memory stores.

    func testResetApplication_CompletesSuccessfully() async {
        await setUpWithSQLiteStore()

        // Given: initial state
        let initialMode = sut.mode

        // When: reset application is called
        await sut.resetApplication()

        // Then: reset completes without errors and state is still valid
        XCTAssertEqual(sut.mode, initialMode, "Mode should remain unchanged after reset")
        XCTAssertNotNil(sut.settings, "Settings should not be nil after reset")
        XCTAssertNotNil(sut.deep, "Deep state should not be nil after reset")
    }

    func testResetApplication_DisablesDetectionIfEnabled() async {
        await setUpWithSQLiteStore()

        // Given: detection is enabled
        sut.ontheflyDetectionEnabled = true
        snapState.startTimer()
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)

        // When: reset application is called
        await sut.resetApplication()

        // Then: detection is disabled and chrome is restored to the default state
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
        XCTAssertTrue(sut.chromeVisible)
    }

    func testResetApplication_CallsDeepReset() async throws {
        await setUpWithSQLiteStore()

        // Given: deep state has some configurations (non-demo)
        let config = DeepConfiguration.create(in: dataController.container.viewContext)
        let configId = UUID()
        config.entityId = configId
        config.creationDate_ = .now
        config.demo = false
        try DeepConfiguration.save(in: dataController.container.viewContext)

        // Verify the config exists
        XCTAssertNotNil(DeepConfiguration.select(configId, in: dataController.container.viewContext))

        // When: reset application is called
        await sut.resetApplication()

        // Then: the original configuration should be deleted
        let deletedConfig = DeepConfiguration.select(configId, in: dataController.container.viewContext)
        XCTAssertNil(deletedConfig, "Original configuration should be deleted after reset")
    }

    func testResetApplication_CallsSettingsReset() async {
        await setUpWithSQLiteStore()

        // Given: settings have been modified
        settings.applicationResetButtonToggle = false
        let initialToggleState = settings.applicationResetButtonToggle

        // When: reset application is called
        await sut.resetApplication()

        // Then: settings toggle state changes
        XCTAssertNotEqual(settings.applicationResetButtonToggle, initialToggleState)
    }

    func testResetApplication_DeletesBrowsingHistory() async {
        await setUpWithSQLiteStore()

        // Given: some browsing history exists
        await demoDataManager.createDemoDataIfNeeded()
        let countBefore = WebHistoryEntry.count(in: dataController.container.viewContext)
        XCTAssertGreaterThan(countBefore, 0)

        // When: reset application is called
        await sut.resetApplication()

        // Then: browsing history is deleted and recreated with demo data
        // Since resetApplication awaits both deleteBrowsingHistory and createDemoDataIfNeeded,
        // the operations should be complete when we reach this point. The resetApplication
        // method calls createDemoDataIfNeeded after deletion, which populates the store
        // with demo pages, so we expect a positive count.
        let countAfter = WebHistoryEntry.count(in: dataController.container.viewContext)
        XCTAssertGreaterThan(countAfter, 0, "Demo data should be recreated after reset")
    }
}
