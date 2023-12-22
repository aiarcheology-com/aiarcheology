//
//  Downloader.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation
import CoreData

enum DownloaderError: Error {
	case invalidObjectInQueue
	case invalidStateInQueue
}

public actor Downloader: ObservableObject {
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
	}

	unowned var appState: AppState
	private var activeDownloads: [UUID: URLSessionDownloadTask] = [:]
	private var pausedDownloads: [UUID: Data?] = [:]

	init(appState: AppState) {
		self.appState = appState
	}

	func downloadTapped(_ item: DownloadItem) async {
		switch item.state {
		case .notStarted, .failed, .cancelled: await handleEvent(item, .start)
		case .downloading: await handleEvent(item, .pause)
		case .paused: await handleEvent(item, .start)
		case .completed: await handleEvent(item, .start)
		}
	}

	func cancelTapped(_ item: DownloadItem) async {
		switch item.state {
		case .downloading, .paused: await handleEvent(item, .cancel)
		default: break // a cancel action does not change anything at this state
		}
	}

	private func handleEvent(_ item: DownloadItem, _ event: Event) async {
		switch (item.state, event) {
		case (.notStarted, .start), (.paused, .start), (.completed, .start), (.failed, .start):
			await transition(item, to: .downloading)
			await startDownload(item)

		case (.downloading, .pause):
			await transition(item, to: .paused)
			await pauseDownload(item)

		case (.downloading, .cancel), (.paused, .cancel):
			await transition(item, to: .cancelled)
			await cancelDownload(item)

		default:
			assert(false, "Invalid transition from \(item.state) with event \(event)")
		}
	}

	private func transition(_ item: DownloadItem, to newState: State) async {
		item.state = newState
		await saveDownloadContext()
	}
}

extension Downloader {

	@MainActor
	private func saveDownloadContext() async {
		let downloadContext = await appState.dataController.container.viewContext
		DownloadItem.save(in: downloadContext)
	}

	func enqueueDownload(for item: DownloadItem) async throws {
		guard item.state == .notStarted || item.state == .failed || item.state == .completed else {
			await transition(item, to: .failed)
			throw DownloaderError.invalidStateInQueue
		}

		guard item.entityId.isNotNil else {
			await transition(item, to: .failed)
			throw DownloaderError.invalidObjectInQueue
		}

		Task {
			await startDownload(item)
		}
	}

	func cancelDownload(_ item: DownloadItem) async {
		guard
			let entityId = item.entityId,
			let downloadTask = activeDownloads[entityId] else { return }
		downloadTask.cancel()
		await transition(item, to: .cancelled)
		activeDownloads.removeValue(forKey: entityId)
	}

	func pauseDownload(_ item: DownloadItem) async {
		guard
			let entityId = item.entityId,
			let downloadTask = activeDownloads[entityId] else { return }

		pausedDownloads[entityId] = await downloadTask.cancelByProducingResumeData()
		await transition(item, to: .paused)
		activeDownloads.removeValue(forKey: entityId)
	}

	private func startDownload(_ item: DownloadItem) async {
		guard let url = item.url, let entityId = item.entityId else { return }

		let downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tmpLocation, response, error in
			guard let self else { return }

			Task { [weak self] in
				if let error = error {
					item.error = error.localizedDescription
					await self?.transition(item, to: .failed)
					return
				}

				guard let tmpLocation = tmpLocation else {
					item.error = "Temporal location of the download file was not created."
					await self?.transition(item, to: .failed)
					return
				}

				await self?.handleDownloadCompletion(for: item, location: tmpLocation)
			}
		}

		downloadTask.resume()
		activeDownloads[entityId] = downloadTask
	}

	private func handleDownloadCompletion(for item: DownloadItem, location: URL) async {
		guard let entityId = item.entityId else {
			item.error = "Download entity id is not initialised."
			await transition(item, to: .failed)
			return
		}
		guard let url = item.url else {
			item.error = "Download entity id is not initialised."
			await transition(item, to: .failed)
			return
		}

		let targetDirectory = Self.constructTargetDirectory(for: entityId)

		do {
			try Self.createDirectoryIfNeeded(at: targetDirectory)
			let fileName = url.lastPathComponent
			let targetPath = targetDirectory.appendingPathComponent(fileName)

			if FileManager.default.fileExists(atPath: targetPath.path) {
				try FileManager.default.removeItem(at: targetPath)
			}

			try FileManager.default.moveItem(at: location, to: targetPath)
			
			item.file = targetPath
			await transition(item, to: .completed)

		} catch let error {
			item.error = error.localizedDescription
			await transition(item, to: .failed)
		}

		activeDownloads.removeValue(forKey: entityId)
	}

	static private func constructTargetDirectory(for entityId: UUID) -> URL {
		let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		return documentDirectory
			.appendingPathComponent("Configurations")
			.appendingPathComponent(entityId.uuidString)
	}

	static private func createDirectoryIfNeeded(at path: URL) throws {
		let fileManager = FileManager.default
		if !fileManager.fileExists(atPath: path.path) {
			try fileManager.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
		}
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
