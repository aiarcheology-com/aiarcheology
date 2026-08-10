//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation
import Vision

@MainActor
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
@MainActor
final class SnapState: ObservableObject {
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
		Publishers.Merge(
			timerTrigger.handleEvents(receiveOutput: { _ in
				LoggingPolicy.debug("[AIA-0587 TRACE] SnapState timer trigger reached publisher", logger: .state)
			}),
			snapshotTrigger.handleEvents(receiveOutput: { _ in
				LoggingPolicy.debug("[AIA-0587 TRACE] SnapState manual trigger reached publisher", logger: .state)
			})
		)
			.handleEvents(
				receiveSubscription: { _ in
					LoggingPolicy.debug("[AIA-0587 TRACE] SnapState combined publisher subscribed", logger: .state)
				},
				receiveCancel: {
					LoggingPolicy.debug("[AIA-0587 TRACE] SnapState combined publisher cancelled", logger: .state)
				}
			)
			.eraseToAnyPublisher()
	}
    func startTimer() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapState startTimer called active=\(timerCancellable != nil) frequency=\(settings.snapFrequency)",
			logger: .state
		)
		guard timerCancellable.isNil else {
			LoggingPolicy.debug("[AIA-0587 TRACE] SnapState startTimer ignored because timer is already active", logger: .state)
			return
		}

			// Start the timer and handle its events by sending them to timerTrigger
		LoggingPolicy.debug("[AIA-0587 TRACE] SnapState sending immediate timer trigger", logger: .state)
		self.timerTrigger.send() // start immediately
		timerCancellable = Timer.publish(every: settings.snapFrequency, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				LoggingPolicy.debug("[AIA-0587 TRACE] SnapState cadence timer fired", logger: .state)
				self?.timerTrigger.send()
			}
		LoggingPolicy.debug("[AIA-0587 TRACE] SnapState cadence timer installed", logger: .state)
	}

	func stopTimer() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapState stopTimer called active=\(timerCancellable != nil)",
			logger: .state
		)
		timerCancellable?.cancel()
		timerCancellable = nil
		LoggingPolicy.debug("[AIA-0587 TRACE] SnapState timer stopped", logger: .state)
	}
}
