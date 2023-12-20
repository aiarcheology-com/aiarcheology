//
//  Downloader.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation
import CoreData

public class Downloader: ObservableObject {
	public enum State: String, CaseIterable, Identifiable {
		case notStarted = "Not Started"
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

	unowned var appState: AppState

	init(appState: AppState) {
		self.appState = appState
	}

	func downloadTapped(_ item: DownloadItem) {
		switch item.state {
		case .notStarted, .failed, .cancelled: handleEvent(item, .start)
		case .downloading: handleEvent(item, .pause)
		case .paused: handleEvent(item, .start)
		case .completed: handleEvent(item, .start)
		}
	}

	func cancelTapped(_ item: DownloadItem) {
		switch item.state {
		case .downloading, .paused: handleEvent(item, .cancel)
		default: break // a cancel action does not change anything at this state
		}
	}

	func handleEvent(_ item: DownloadItem, _ event: Event) {
		switch (item.state, event) {
			case (.notStarted, .start):
				transition(item, to: .downloading)

			case (.downloading, .pause):
				transition(item, to: .paused)

			case (.downloading, .cancel),
				(.paused, .cancel):
				transition(item, to: .cancelled)

			case (.downloading, .fail),
				(.paused, .fail):
				transition(item, to: .failed)

			case (.downloading, .complete):
				transition(item, to: .completed)

			case (.paused, .start):
				transition(item, to: .downloading)

			default:
				assert(false, "Invalid transition from \(item.state) with event \(event)")
		}
	}

	private func transition(_ item: DownloadItem, to newState: State) {
		let oldState = item.state
		print("Transitioned to \(newState)")
		

	}
}

extension DownloadItem: CoreDataManageable {
	static func create(in context: NSManagedObjectContext) -> Self {
		let newItem = Self(context: context)
		newItem.entityId = UUID()
		return newItem
	}

}

extension DownloadItem {
	typealias State = Downloader.State

	public var state: Downloader.State {
		get {
			let defaultReturn = State.notStarted
			guard let state = state_ else { return defaultReturn }
			switch state {
				case State.notStarted.id: return .notStarted
				case State.downloading.id: return .downloading
				case State.paused.id: return .paused
				case State.cancelled.id: return .cancelled
				case State.failed.id: return .failed
				case State.completed.id: return .completed
				default: return defaultReturn
			}
		}
		set {
			state_ = newValue.id
		}
	}

	public var stateChanged: String {
		return DateFormatter.longDateFormater.string(from: stateChanged_ ?? .now)
	}
}

// Add the validations using the core data's api:
extension DownloadItem {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		try validateDownloadItem()
	}

	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try validateDownloadItem()
	}

	private func validateDownloadItem() throws {
		if url.isNil || url?.absoluteString.isEmpty == true {
			throw validationError(forKey: "url", error: "Model's url is required.")
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw validationError(forKey: "entityId", error: "Model's entityId is required.")
		}
	}

	private func validationError(forKey key: String, error: String) -> NSError {
			// TODO: add the error codes
		return NSError(domain: "DownloadItem", code: 1000, userInfo: [
			NSLocalizedDescriptionKey: "Validation error - \(key): \(error)"
		])
	}
}
