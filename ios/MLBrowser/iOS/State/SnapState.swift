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

/// One request to capture the current web content for a particular detection run. The session
/// assigns a new run identifier whenever detection starts, stops, or resets; a late snapshot from
/// an older run must never feed the newly-started one.
struct SnapshotRequest: Equatable, Sendable {
	let runID: UInt64
	let sequence: UInt64
}

@MainActor
final class SnapState: ObservableObject {
	var settings: Settings
	var timerCancellable: Cancellable?
	private let snapshotTrigger = PassthroughSubject<SnapshotRequest, Never>()
	private let timerTrigger = PassthroughSubject<SnapshotRequest, Never>()
	private var nextRequestSequence: UInt64 = 0
	var delayedTimer: Bool = false
	
	@Published var snap: Snapshot?

	init(settings: Settings) {
		self.settings = settings
	}

	var combinedPublishers: AnyPublisher<SnapshotRequest, Never> {
		Publishers.Merge(timerTrigger, snapshotTrigger)
			.eraseToAnyPublisher()
	}

	/// Starts the timer for an explicitly-owned detection run and immediately queues its first
	/// request. The receiver is deliberately a request publisher, rather than a bare pulse, so it
	/// can retain the initial work until both the SwiftUI consumer and WKWebView are actually live.
	func startTimer(for runID: UInt64) {
		guard timerCancellable.isNil else { return }

		requestTimerSnapshot(for: runID)
		timerCancellable = Timer.publish(every: settings.snapFrequency, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				self?.requestTimerSnapshot(for: runID)
			}
	}

	/// Requests one additional pass in the current run, for example after a driver finishes
	/// registering. Only `DetectionSessionState` calls this public command path.
	func requestSnapshot(for runID: UInt64) {
		nextRequestSequence &+= 1
		snapshotTrigger.send(SnapshotRequest(runID: runID, sequence: nextRequestSequence))
	}

	func stopTimer() {
		timerCancellable?.cancel()
		timerCancellable = nil
	}

	private func requestTimerSnapshot(for runID: UInt64) {
		nextRequestSequence &+= 1
		timerTrigger.send(SnapshotRequest(runID: runID, sequence: nextRequestSequence))
	}
}
