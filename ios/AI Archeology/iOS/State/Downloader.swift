//
//  Downloader.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation

class Downloader: ObservableObject {
	enum State: String, CaseIterable, Identifiable {
		case notStarted = "NotStarted"
		case downloading = "Downloading"
		case paused = "Paused"
		case cancelled = "Cancelled"
		case failed = "Failed"
		case completed = "Completed"

		public var id: String { self.rawValue }
	}

	enum Event {
		case start
		case pause
		case cancel
		case fail
		case complete
	}

	private var state: State = .notStarted

	func handleEvent(_ event: Event) {
		switch (state, event) {
			case (.notStarted, .start):
				transition(to: .downloading)

			case (.downloading, .pause):
				transition(to: .paused)

			case (.downloading, .cancel),
				(.paused, .cancel):
				transition(to: .cancelled)

			case (.downloading, .fail),
				(.paused, .fail):
				transition(to: .failed)

			case (.downloading, .complete):
				transition(to: .completed)

			case (.paused, .start):
				transition(to: .downloading)

			default:
				assert(false, "Invalid transition from \(state) with event \(event)")
		}
	}

	private func transition(to newState: State) {
		let oldState = state
		print("Transitioned to \(newState)")
		

	}

	func currentState() -> State {
		return state
	}
}

extension DownloadItem: CoreDataManageable {}
