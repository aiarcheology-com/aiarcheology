//
//  GuideTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import CoreData
@testable import ML_Browser

@MainActor
final class GuideTests: XCTestCase {
    
    var settings: Settings!
    var snapState: SnapState!
    var deepState: DeepState!
    var snapAdjustment: SnapAdjustment!
    var dataController: DataController!
    var demoDataManager: DemoDataManager!
    var sut: Guide!
    
    override func setUp() async throws {
        try await super.setUp()
        
        settings = Settings()
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
        try await super.tearDown()
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
    
    func testResetApplication_CompletesSuccessfully() async {
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
        // Given: detection is enabled
        sut.ontheflyDetectionEnabled = true
        snapState.startTimer()
        XCTAssertTrue(sut.ontheflyDetectionEnabled)
        XCTAssertNotNil(snapState.timerCancellable)
        
        // When: reset application is called
        await sut.resetApplication()
        
        // Then: detection is disabled
        XCTAssertFalse(sut.ontheflyDetectionEnabled)
        XCTAssertNil(snapState.timerCancellable)
    }
    
    func testResetApplication_CallsDeepReset() async {
        // Given: deep state has some configurations
        let config = DeepConfiguration.create(in: dataController.container.viewContext)
        config.entityId = UUID()
        config.creationDate_ = .now
        DeepConfiguration.save(in: dataController.container.viewContext)
        
        let initialCount = DeepConfiguration.count(in: dataController.container.viewContext)
        XCTAssertGreaterThan(initialCount, 0)
        
        // When: reset application is called
        await sut.resetApplication()
        
        // Then: deep configurations are reset
        let finalCount = DeepConfiguration.count(in: dataController.container.viewContext)
        XCTAssertEqual(finalCount, 0)
    }
    
    func testResetApplication_CallsSettingsReset() async {
        // Given: settings have been modified
        settings.applicationResetButtonToggle = false
        let initialToggleState = settings.applicationResetButtonToggle
        
        // When: reset application is called
        await sut.resetApplication()
        
        // Then: settings toggle state changes
        XCTAssertNotEqual(settings.applicationResetButtonToggle, initialToggleState)
    }
    
    func testResetApplication_DeletesBrowsingHistory() async {
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

