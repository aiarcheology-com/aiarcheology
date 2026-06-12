//
//  Settings.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

@MainActor
protocol Validatable {
	func validate() throws
}

enum ValidationError: Error {
	case invalidData(String)
}

// TODO: use another way to handle the defaults, @dynamicMemberLookup, or so
final class Settings: ObservableObject, Validatable {

	private enum UserDefaultsKeys {
		static let lastPage = "lastPage"
		static let isDetectionPaused = "isDetectionPaused"
		static let keepSlideShowActive = "keepSlideShowActive"
		static let reopenLastPage = "reopenLastPage"
		static let isFirstLaunch = "isFirstLaunch"
		static let showIdentifiers = "showIdentifiers"
		static let snapAfterAppStart = "snapAfterAppStart"
		static let snapFrequency = "snapFrequency"
		static let resetHistory = "resetHistory"
		static let sizeHistory = "sizeHistory"
		static let defaultPage = "defaultPage"
		static let removeAnnotationOnDrag = "removeAnnotationOnDrag"
		static let entityId = "entityId"
		static let fullscreenDetection = "fullscreenDetection"
		static let tiledDetection = "tiledDetection"
	}

	public var isFirstLaunchMarked: Bool = false

	@Published public var isDetectionPaused: Bool = false

	@Published public var keepSlideShowActive: Bool {
		didSet {
			UserDefaults.standard.set(keepSlideShowActive, forKey: UserDefaultsKeys.keepSlideShowActive)
		}
	}

	@Published public var applicationResetButtonToggle: Bool = false

	@Published public var historySize: Int {
		didSet {
			UserDefaults.standard.set(historySize, forKey: UserDefaultsKeys.sizeHistory)
		}
	}

	@Published public var snapAfterAppStart: Bool {
		didSet {
			UserDefaults.standard.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
		}
	}

	@Published public var reopenLastPage: Bool {
		didSet {
			UserDefaults.standard.set(reopenLastPage, forKey: UserDefaultsKeys.reopenLastPage)
		}
	}

	@Published public var snapFrequency: Double {
		didSet {
			UserDefaults.standard.set(snapFrequency, forKey: UserDefaultsKeys.snapFrequency)
		}
	}

	@Published public var resetHistory: Bool {
		didSet {
			UserDefaults.standard.set(resetHistory, forKey: UserDefaultsKeys.resetHistory)
		}
	}

	@Published public var defaultPage: URL? {
		didSet {
			UserDefaults.standard.set(defaultPage, forKey: UserDefaultsKeys.defaultPage)
		}
	}

	@Published public var lastPage: URL? {
		didSet {
			UserDefaults.standard.set(lastPage, forKey: UserDefaultsKeys.lastPage)
		}
	}

	@Published public var removeAnnotationOnDrag: Bool {
		didSet {
			UserDefaults.standard.set(removeAnnotationOnDrag, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		}
	}

	@Published public var showIdentifiers: Bool {
		didSet {
			UserDefaults.standard.set(showIdentifiers, forKey: UserDefaultsKeys.showIdentifiers)
		}
	}

	/// When enabled, starting detection hides the browser chrome (fullscreen mode
	/// with the floating toggle button). When disabled, detection runs with the
	/// chrome visible and no floating button is shown.
	@Published public var fullscreenDetection: Bool {
		didSet {
			UserDefaults.standard.set(fullscreenDetection, forKey: UserDefaultsKeys.fullscreenDetection)
		}
	}

	/// AIA-0217: when enabled, each detection snapshot runs through 6 regions (4 quadrants
	/// + center + full frame) instead of one full-frame pass — edge artifacts reach the
	/// model at roughly double resolution at the cost of 6× inference per snapshot.
	@Published public var tiledDetection: Bool {
		didSet {
			UserDefaults.standard.set(tiledDetection, forKey: UserDefaultsKeys.tiledDetection)
		}
	}

	@Published public var entityId: UUID? {
		didSet {
			UserDefaults.standard.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		}
	}

	@Published public var isFirstLaunch: Bool { // is being reseted in MLBrowser
		didSet {
			UserDefaults.standard.set(isFirstLaunch, forKey: UserDefaultsKeys.isFirstLaunch)
		}
	}

	init() {
		let defaultValues: [String: Any] = [
			UserDefaultsKeys.keepSlideShowActive: true,
			UserDefaultsKeys.sizeHistory: 30,
            UserDefaultsKeys.reopenLastPage: false,
            UserDefaultsKeys.isFirstLaunch: true,
            UserDefaultsKeys.showIdentifiers: false,
            UserDefaultsKeys.snapAfterAppStart: false,
            UserDefaultsKeys.snapFrequency: 3.0,
            UserDefaultsKeys.resetHistory: false,
            // swiftlint:disable:next force_unwrapping
            UserDefaultsKeys.defaultPage: URL(string: "https://www.google.com")!,
            UserDefaultsKeys.removeAnnotationOnDrag: false,
            UserDefaultsKeys.entityId: UUID().uuidString,
            // Off by default: hitting play and losing the chrome surprises
            // first-time users; fullscreen detection is an opt-in.
            UserDefaultsKeys.fullscreenDetection: false,
            // On by default: simulator verification confirmed the edge-detection win
            // (AIA-0217 plan, decision 1); the toggle exists to opt out of the 6x
            // inference cost.
            UserDefaultsKeys.tiledDetection: true
        ]

		// Register default values
		UserDefaults.standard.register(defaults: defaultValues)
		self.keepSlideShowActive = UserDefaults.standard.bool(forKey: UserDefaultsKeys.keepSlideShowActive)
		self.historySize = UserDefaults.standard.integer(forKey: UserDefaultsKeys.sizeHistory)
		self.reopenLastPage = UserDefaults.standard.bool(forKey: UserDefaultsKeys.reopenLastPage)
		self.isFirstLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isFirstLaunch)
		self.showIdentifiers = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showIdentifiers)
		self.snapAfterAppStart = UserDefaults.standard.bool(forKey: UserDefaultsKeys.snapAfterAppStart)
		self.snapFrequency = UserDefaults.standard.double(forKey: UserDefaultsKeys.snapFrequency)
		self.resetHistory = UserDefaults.standard.bool(forKey: UserDefaultsKeys.resetHistory)
		self.defaultPage = UserDefaults.standard.url(forKey: UserDefaultsKeys.defaultPage)
		self.lastPage = UserDefaults.standard.url(forKey: UserDefaultsKeys.lastPage)
		self.removeAnnotationOnDrag = UserDefaults.standard.bool(forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		self.fullscreenDetection = UserDefaults.standard.bool(forKey: UserDefaultsKeys.fullscreenDetection)
		self.tiledDetection = UserDefaults.standard.bool(forKey: UserDefaultsKeys.tiledDetection)
		if let uuidString = UserDefaults.standard.string(forKey: UserDefaultsKeys.entityId),
		   let uuid = UUID(uuidString: uuidString) {
			self.entityId = uuid
		}
	}

	func validate() throws {
		if (snapFrequency >= 1.0 && snapFrequency <= 10.0).not {
			throw ValidationError.invalidData("Settings's snapFrequency is required between 1.0 and 10.0!")
		}
		if defaultPage.isNotNil &&
			defaultPage?.absoluteString.isEmpty == false &&
			(defaultPage?.absoluteString.browserInputType == .url).not {
			throw ValidationError.invalidData("Settings's defaultPage with valid URL is required.")
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw ValidationError.invalidData("Settings's entityId is required.")
		}
	}

	func reset() {
		isDetectionPaused = false
		keepSlideShowActive = true
		historySize = 30
		reopenLastPage = false
		isFirstLaunchMarked = false
		isFirstLaunch = true
		showIdentifiers = false
		snapAfterAppStart = false
		snapFrequency = 3.0
		resetHistory = false
		defaultPage = URL(string: "https://www.google.com")
		removeAnnotationOnDrag = false
		entityId = UUID()
		lastPage = nil
		fullscreenDetection = false
		tiledDetection = true

		UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.lastPage)
		UserDefaults.standard.set(keepSlideShowActive, forKey: UserDefaultsKeys.keepSlideShowActive)
		UserDefaults.standard.set(historySize, forKey: UserDefaultsKeys.sizeHistory)
		UserDefaults.standard.set(reopenLastPage, forKey: UserDefaultsKeys.reopenLastPage)
		UserDefaults.standard.set(isFirstLaunch, forKey: UserDefaultsKeys.isFirstLaunch)
		UserDefaults.standard.set(showIdentifiers, forKey: UserDefaultsKeys.showIdentifiers)
		UserDefaults.standard.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
		UserDefaults.standard.set(snapFrequency, forKey: UserDefaultsKeys.snapFrequency)
		UserDefaults.standard.set(resetHistory, forKey: UserDefaultsKeys.resetHistory)
		UserDefaults.standard.set(defaultPage, forKey: UserDefaultsKeys.defaultPage)
		UserDefaults.standard.set(removeAnnotationOnDrag, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		UserDefaults.standard.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		UserDefaults.standard.set(fullscreenDetection, forKey: UserDefaultsKeys.fullscreenDetection)
		UserDefaults.standard.set(tiledDetection, forKey: UserDefaultsKeys.tiledDetection)
	}
}
