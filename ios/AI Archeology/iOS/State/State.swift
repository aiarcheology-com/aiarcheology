//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation

enum AppMode: Int, Codable, Hashable, Identifiable {
	var id: Self { self }
    case web
    case gallery
    case cloud
    case camera
	// case stream
	// case api
	static var tabOrder: [AppMode] { [.web, .gallery, .cloud, .camera] }
}

class AppState: ObservableObject {
    var guide = Guide()
	var deep = DeepState()
	var snap = SnapState()
}

import Vision
import SwiftUI
class DeepState: ObservableObject {
	var frame: CGRect = .zero
	@Published var detectedObservations: [VNRecognizedObjectObservation] = []
	@Published var classifiedObservations: [VNClassificationObservation] = []
}

class Guide: ObservableObject {
    @Published var mode = AppMode.web
    @Published var presentedSideMenu = false

    func togglingSideMenu() {
        presentedSideMenu.toggle()
    }
}

import Combine
class SnapState: ObservableObject {
	var timerCancellable: Cancellable?
	let snapshotTrigger = PassthroughSubject<Void, Never>()
	let timerTrigger = PassthroughSubject<Void, Never>()

	var combinedPublishers: AnyPublisher<Void, Never> {
		Publishers.Merge(timerTrigger, snapshotTrigger)
			.eraseToAnyPublisher()
	}

	func startTimer() {
			// Start the timer and handle its events by sending them to timerTrigger
		timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
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

