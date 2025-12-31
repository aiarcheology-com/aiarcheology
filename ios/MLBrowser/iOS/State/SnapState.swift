//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation
import Vision

final class SnapAdjustment: ObservableObject {
	static let defaultBrightness = 0.0
	static let defaultContrast = 1.0
	static let defaultSaturation = 1.0
	init() {
	}

	// TODO: Possibly store together in the Page History
	@Published var brightness: Double = defaultBrightness
	@Published var contrast: Double = defaultContrast
	@Published var saturation: Double = defaultSaturation
}

import Combine
class SnapState: ObservableObject {
	var settings: Settings
	var timerCancellable: Cancellable?
	let snapshotTrigger = PassthroughSubject<Void, Never>()
	let timerTrigger = PassthroughSubject<Void, Never>()
	var delayedTimer: Bool = false
	
	@Published var snap: Snapshot?

	init(settings: Settings) {
		self.settings = settings
	}

	var combinedPublishers: AnyPublisher<Void, Never> {
		Publishers.Merge(timerTrigger, snapshotTrigger)
			.eraseToAnyPublisher()
	}
    @MainActor func startTimer() {
		guard timerCancellable.isNil else { return }

			// Start the timer and handle its events by sending them to timerTrigger
		self.timerTrigger.send() // start immediately
		timerCancellable = Timer.publish(every: settings.snapFrequency, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				self?.timerTrigger.send()
			}
	}

	func stopTimer() {
		timerCancellable?.cancel()
		timerCancellable = nil
	}
}
