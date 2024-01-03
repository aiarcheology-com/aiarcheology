//
//  Guide.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

final class Guide: ObservableObject {
	unowned var appState: AppState
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var presentSettings: Bool = false
	@Published var pageToOpen: URL?
	@Published var addressBarMenu: [URL] = []
	@Published var addressSelected: URL?

	init(appState: AppState) {
		self.appState = appState
	}

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}

	func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			appState.snap.stopTimer()
			appState.snap.startTimer()
		}
	}

	func historySelected(_ item: URL) {
		addressSelected = item
		addressBarMenu = []
	}

	func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			appState.snap.startTimer()
		} else {
			appState.snap.stopTimer()
		}
	}

	func settingsTapped() {
		presentSettings = true
	}

	func resetApplication() {
		if appState.guide.ontheflyDetectionEnabled {
			appState.guide.ontheflyDetectionTapped()
		}
		appState.deep.reset()
		appState.settings.reset()
		appState.settings.applicationResetButtonToggle.toggle()
		self.appState.deleteBrowsingHistory()
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self else { return }
			self.appState.createDemoEntities()
		}
	}
}
