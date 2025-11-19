//
//  Guide.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

final class Guide: ObservableObject {
	var snap: any SnapStateManaging
    var deep: any DeepStateManaging
    var settings: any SettingsProviding
    unowned var snapAdjustment: SnapAdjustment
    let dataController: DataControlling
    let demoDataManager: DemoDataManaging
    
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var presentSettings: Bool = false
	@Published var pageToOpen: URL?
	@Published var addressBarMenu: [URL] = []
	@Published var addressSelected: URL?

	init(snap: any SnapStateManaging, deep: any DeepStateManaging, settings: any SettingsProviding, dataController: DataControlling, demoDataManager: DemoDataManaging, snapAdjustment: SnapAdjustment) {
		self.snap = snap
        self.deep = deep
        self.settings = settings
        self.dataController = dataController
        self.demoDataManager = demoDataManager
        self.snapAdjustment = snapAdjustment
	}

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}

    @MainActor func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			snap.stopTimer()
			snap.startTimer()
		}
	}

	func historySelected(_ item: URL) {
		addressSelected = item
		addressBarMenu = []
	}

    @MainActor func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			snap.startTimer()
		} else {
			snap.stopTimer()
		}
	}

	func settingsTapped() {
		presentSettings = true
	}

    @MainActor func resetApplication() {
		if ontheflyDetectionEnabled {
			ontheflyDetectionTapped()
		}
		deep.reset()
		settings.reset()
		settings.applicationResetButtonToggle.toggle()
		demoDataManager.deleteBrowsingHistory()
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self else { return }
			self.demoDataManager.createDemoEntities()
		}
	}
}
