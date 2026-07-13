//
//  Downloader.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

import Foundation
import CoreData
import Combine
import Network
import OSLog

enum DownloaderError: Error {
    case invalidObjectInQueue
    case invalidStateInQueue
}

// MARK: - Task Protocols for Testing

/// Minimal protocol for task identification - used in delegate forwarding methods
/// that only need to read taskDescription.
protocol TaskIdentifiable: AnyObject, Sendable {
    var taskDescription: String? { get set }
}

/// Protocol abstraction for URLSessionDownloadTask to enable testing without subclassing.
/// URLSessionDownloadTask.init() is deprecated in iOS 13+, so we use protocol-based mocking instead.
protocol DownloadTaskProtocol: TaskIdentifiable {
    var state: URLSessionTask.State { get }
    func resume()
    func cancel()
    func cancel(byProducingResumeData completionHandler: @escaping @Sendable (Data?) -> Void)
}

extension URLSessionTask: TaskIdentifiable {}
extension URLSessionDownloadTask: DownloadTaskProtocol {}

// MARK: - ActiveDownload

@MainActor
final class ActiveDownload: Identifiable, Comparable, Hashable, ObservableObject {
    let itemId: UUID
    @Published var progress: Double = 0.0
    @Published var totalBytesWritten: Int = 0
    @Published var totalBytesExpected: Int = 0
    
    nonisolated var id: UUID {
        return itemId
    }
    let started: Date = .now
    // Strong reference: URLSession retains its tasks until completion anyway, and a weak
    // reference here silently broke pause/cancel whenever the ref was released early.
    let task: any DownloadTaskProtocol

    /// Set before cancel(byProducingResumeData:) so the completion delegate can
    /// distinguish a pause from a true cancel. Checking `item.resumeData` alone races:
    /// the resume data is persisted via an async MainActor Task that may run after
    /// the cancelled-completion callback.
    var isPausing = false

    init(task: any DownloadTaskProtocol, itemId: UUID) {
        self.task = task
        self.itemId = itemId
    }
    
    nonisolated static func < (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.started < rhs.started
    }
    
    nonisolated static func == (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.id == rhs.id
    }
    
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// In-memory progress for a bounded multi-file Core ML package job. The job manifest itself is
/// persisted on its `DownloadItem`, so a failed or interrupted package can be restarted.
@MainActor
final class ActivePackageDownload: Identifiable, ObservableObject {
	let id: UUID
	@Published var progress: Double = 0.0
	@Published var totalBytesWritten: Int = 0
	@Published var totalBytesExpected: Int = 0
	@Published var completedFileCount = 0
	@Published var totalFileCount = 0
	var task: Task<Void, Never>?

	init(itemId: UUID) {
		self.id = itemId
	}
}

struct PackageFileProgress: Equatable {
	let completedFileCount: Int
	let totalFileCount: Int
}

private struct PackageDownloadManifest: Codable {
	private static let kind = "catalog-coreml-package-v1"

	let jobKind: String
	let files: [CatalogFile]

	init(files: [CatalogFile]) {
		self.jobKind = Self.kind
		self.files = files
	}

	var isValid: Bool {
		jobKind == Self.kind && files.isEmpty == false
	}

	var isPackage: Bool {
		files.contains { file in
			file.relativePath.split(separator: "/").contains { $0.lowercased().hasSuffix(".mlpackage") }
		}
	}
}

private final class DownloaderSessionDelegateProxy: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    weak var owner: Downloader?
    
    init(owner: Downloader) {
        self.owner = owner
        super.init()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else { return }
            owner.sessionTaskDidComplete(session: session, task: task, error: error)
        }
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak owner] in
            owner?.sessionDownloadDidWriteData(session: session,
                                               downloadTask: downloadTask,
                                               bytesWritten: bytesWritten,
                                               totalBytesWritten: totalBytesWritten,
                                               totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard
            let idString = downloadTask.taskDescription,
            let id = UUID(uuidString: idString)
        else {
            LoggingPolicy.error("Download task identifier not defined or invalid on completion", logger: .networking)
            return
        }
        
        LoggingPolicy.info("Download finished for item \(id.uuidString)", logger: .networking)
        
        // CRITICAL: Move file synchronously BEFORE returning from delegate
        let fileResult: Result<URL, Error>
        do {
            let targetURL = try FileManager.moveModelToDocuments(from: location, configurationId: id)
            fileResult = .success(targetURL)
        } catch {
            fileResult = .failure(error)
        }
        
        // Update Core Data on main actor
        Task { @MainActor [weak owner] in
            owner?.handleDownloadCompletion(itemId: id, fileURL: fileResult)
        }
    }

    /// Called when all background URLSession events have been delivered to the app.
    /// We must call the completion handler captured in `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak owner] in
            owner?.backgroundSessionDidFinishEvents()
        }
    }
}

@MainActor
final public class Downloader: NSObject, ObservableObject {
    public enum State: String, CaseIterable, Identifiable {
        case notStarted = "Not started"
        case downloading = "Downloading"
        case paused = "Paused"
        case cancelled = "Cancelled"
        case failed = "Failed"
        case complete = "Complete"
        case imported = "Imported"
        case importFailed = "Import failed"

        public var id: String { self.rawValue }

        /// Localized display name for the download state
        public var localizedName: String {
            switch self {
            case .notStarted: return L10n.DownloadState.notStarted
            case .downloading: return L10n.DownloadState.downloading
            case .paused: return L10n.DownloadState.paused
            case .cancelled: return L10n.DownloadState.cancelled
            case .failed: return L10n.DownloadState.failed
            case .complete: return L10n.DownloadState.complete
            case .imported: return L10n.DownloadState.imported
            case .importFailed: return L10n.DownloadState.importFailed
            }
        }
    }
    
    enum Event {
        case start
        case pause
        case cancel
    }

    // MARK: - Background URLSession

    /// Single background session identifier for all download tasks.
    static let backgroundSessionIdentifier = "com.aiarcheology.mlbrowser.download"

    /// Background sessions are disabled under XCTest runs (stability + determinism).
    static var shouldUseBackgroundSession: Bool {
        !AppEnvironment.isRunningUnderAnyTests
    }
    
    let dataController: DataController
    @Published private(set) var activeDownloads: [UUID: ActiveDownload] = [:]
    @Published private(set) var activePackageDownloads: [UUID: ActivePackageDownload] = [:]
    
    private let networkMonitor = NWPathMonitor()
    private lazy var delegateProxy: DownloaderSessionDelegateProxy = DownloaderSessionDelegateProxy(owner: self)
	private let packageDownloader: CatalogPackageDownloader
	private var packageManifests: [UUID: PackageDownloadManifest] = [:]

    /// Completion handler provided by iOS when the app is relaunched to process background session events.
    /// Must be called once all background events are handled.
    var backgroundSessionCompletionHandler: (() -> Void)?

    private lazy var foregroundSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // AIA-0318 UI-test harness: when the `stubDownloads` launch flag is set, intercept downloads
        // with StubDownloadURLProtocol so tests never hit the network. UI-test downloads already use
        // this foreground session (shouldUseBackgroundSession is false under tests), and URLProtocol
        // works with .default sessions (not background ones).
        //
        // Gated on `isRunningUITests` so the shipping/normal path is completely untouched: it neither
        // reassigns `protocolClasses` (which would turn Foundation's default `nil` into `[]` and drop
        // the built-in protocols) nor decodes `UI_TEST_CONFIG` (which would `fatalError` on malformed
        // input outside UI tests).
        if AppEnvironment.isRunningUITests {
            configuration.protocolClasses = Self.foregroundProtocolClasses(
                base: configuration.protocolClasses ?? [],
                isUITest: true,
                stubDownloads: UITestLaunchConfiguration.fromEnvironment?.stubDownloads == true
            )
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: queue)
    }()

    /// Pure decision for the foreground session's protocol classes (AIA-0318). Prepends the
    /// download stub only under UI tests with the `stubDownloads` flag, preserving the existing
    /// classes; otherwise returns `base` unchanged. Extracted so the gating is unit-testable.
    nonisolated static func foregroundProtocolClasses(base: [AnyClass], isUITest: Bool, stubDownloads: Bool) -> [AnyClass] {
        guard isUITest, stubDownloads else { return base }
        return [StubDownloadURLProtocol.self] + base
    }

	/// A completed download's actual byte count is authoritative when the source did not provide
	/// a `Content-Length` or catalog size. This keeps completed jobs from displaying `0 KB` as the
	/// total after the transient downloader progress has been discarded.
	nonisolated static func completedExpectedBytes(written: Int, expected: Int) -> Int {
		expected > 0 ? expected : written
	}

    private lazy var backgroundSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: queue)
    }()
    
    // Test hook
    var sessionFactory: ((URLSessionConfiguration, URLSessionDelegate?, OperationQueue?) -> URLSession)?
        
    init(dataController: DataController, packageDownloader: CatalogPackageDownloader = CatalogPackageDownloader()) {
        self.dataController = dataController
		self.packageDownloader = packageDownloader
        super.init()
        
		LoggingPolicy.debug("Downloader initialized, starting network monitor", logger: .networking)
        self.networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            switch path.status {
            case .satisfied:
                LoggingPolicy.debug("Network connection satisfied", logger: .networking)
            default:
                LoggingPolicy.warning("Network connection issue detected, pausing active downloads", logger: .networking)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    activeDownloads.values.forEach { download in
                        // Fetch the managed object to update error state
                        if let item = DownloadItem.select(download.id, in: self.dataController.container.viewContext) {
                            item.error = "There are issues with your \(self.getNetworkType(path)) connection. The download has been paused."
                            self.handleEvent(item, .pause)
                        }
                    }
                }
            }
        }
        self.networkMonitor.start(queue: DispatchQueue(label: "Network Monitor"))
    }
    
    private func getNetworkType(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) {
            return "WiFi"
        } else if path.usesInterfaceType(.cellular) {
            return "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            return "Ethernet"
        } else {
            return "Internet"
        }
    }

    // MARK: - Background session management

    /// Reconnects to tasks in the background session and restores `activeDownloads`.
    ///
    /// Call this on app launch and when iOS relaunches the app for background URLSession events.
    func reconnectBackgroundSession() {
        guard Self.shouldUseBackgroundSession else {
            LoggingPolicy.debug("Skipping background session reconnection (tests)", logger: .networking)
            return
        }

        // Note: backgroundSession is a lazy property. Accessing it here is safe because
        // this method is called after Downloader initialization completes and Downloader
        // is @MainActor-confined (lazy initialization itself is NOT thread-safe).
        // The delegateProxy (also lazy) will be initialized when backgroundSession is created.
        backgroundSession.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Build a set of active task IDs for quick lookup
                var activeTaskIds = Set<UUID>()

                for task in downloadTasks {
                    guard
                        let idString = task.taskDescription,
                        let id = UUID(uuidString: idString)
                    else {
                        LoggingPolicy.warning("Background download task missing/invalid taskDescription", logger: .networking)
                        continue
                    }

                    activeTaskIds.insert(id)
                    self.activeDownloads[id] = ActiveDownload(task: task, itemId: id)

                    if let item = DownloadItem.select(id, in: self.dataController.container.viewContext),
                       item.state != .downloading {
                        self.transitionAndSave(item, to: .downloading)
                    }
                }

                if !downloadTasks.isEmpty {
                    LoggingPolicy.info("Reconnected \(downloadTasks.count) background download task(s)", logger: .networking)
                }

                // Recover orphaned downloads: items marked as .downloading but with no active task
                self.recoverOrphanedDownloads(activeTaskIds: activeTaskIds)
            }
        }
    }

    /// Recovers downloads that were interrupted by an abrupt app termination.
    ///
    /// Checks for items in `.downloading` state that have no corresponding background task.
    /// - Items with `resumeData`: transition to `.paused` (can be resumed)
    /// - Items without `resumeData`: transition to `.failed` (must restart)
    private func recoverOrphanedDownloads(activeTaskIds: Set<UUID>) {
        let ctx = dataController.container.viewContext
        let fetchRequest = DownloadItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(DownloadItem.state_), State.downloading.rawValue)

        guard let downloadingItems = try? ctx.fetch(fetchRequest) else { return }

        for item in downloadingItems {
            let entityId = item.entityId

            // Skip items that have an active background task
            guard !activeTaskIds.contains(entityId) else { continue }

            if item.resumeData != nil {
                // Has resume data: transition to paused (user can resume)
                LoggingPolicy.info("Recovered orphaned download \(entityId.uuidString) with resume data -> paused", logger: .networking)
                transitionAndSave(item, to: .paused)
            } else if item.progress > 0 {
                // Partial progress but no resume data: mark as failed with helpful message
                LoggingPolicy.warning("Orphaned download \(entityId.uuidString) has no resume data -> failed", logger: .networking)
                item.error = L10n.Download.Error.interruptedNoResumeData
                transitionAndSave(item, to: .failed)
            } else {
                // No progress: reset to not started
                LoggingPolicy.info("Orphaned download \(entityId.uuidString) with no progress -> not started", logger: .networking)
                transitionAndSave(item, to: .notStarted)
            }
        }
    }

    /// Called by the URLSession delegate when the background session finished delivering all events.
    func backgroundSessionDidFinishEvents() {
        guard let handler = backgroundSessionCompletionHandler else { return }
        backgroundSessionCompletionHandler = nil
        handler()
    }

	/// Creates a persisted download item for a multi-file Core ML package. The manifest is kept on
	/// the item instead of an ephemeral view state so a failed package can be retried after relaunch.
	func makePackageDownloadItem(files: [CatalogFile], in context: NSManagedObjectContext) throws -> DownloadItem {
		guard let firstFile = files.first else {
			throw CatalogError.noInstallableArtifact
		}

		let manifest = PackageDownloadManifest(files: files)
		let item = DownloadItem.create(in: context)
		item.url = firstFile.resolveURL
		item.resumeData = try JSONEncoder().encode(manifest)
		item.transition(to: .draft)
		try DownloadItem.save(in: context)
		packageManifests[item.entityId] = manifest
		return item
	}

	/// Returns the persisted download for a catalog artifact, creating it only the first time the
	/// artifact is opened. This lets a catalog row reopen its active, paused, completed, or failed
	/// download instead of creating a competing job.
	func catalogDownloadItem(files: [CatalogFile], in context: NSManagedObjectContext) throws -> DownloadItem {
		guard let firstFile = files.first else {
			throw CatalogError.noInstallableArtifact
		}
		let isSingleModelFile = files.count == 1 && firstFile.relativePath.lowercased().hasSuffix(".mlmodel")

		let request = DownloadItem.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", #keyPath(DownloadItem.url), firstFile.resolveURL as NSURL)
		request.sortDescriptors = [NSSortDescriptor(keyPath: \DownloadItem.stateChanged_, ascending: false)]
		request.fetchLimit = 1
		if let existingItem = try context.fetch(request).first {
			if isSingleModelFile, isCatalogDownload(existingItem) {
				// Early catalog versions derived Google Drive's generic `/download` path as the
				// filename, creating a manifest-backed job for a single file. Reopen that same
				// historical job as the ordinary single-file download it was always meant to be.
				packageManifests.removeValue(forKey: existingItem.entityId)
				existingItem.resumeData = nil
				try DownloadItem.save(in: context)
			}
			if isSingleModelFile, firstFile.xetFile != nil, isCatalogDownload(existingItem) == false,
				existingItem.state != .downloading {
				let manifest = PackageDownloadManifest(files: files)
				existingItem.resumeData = try JSONEncoder().encode(manifest)
				packageManifests[existingItem.entityId] = manifest
				try DownloadItem.save(in: context)
			}
			return existingItem
		}

		if isSingleModelFile == false || firstFile.xetFile != nil {
			return try makePackageDownloadItem(files: files, in: context)
		}

		let item = DownloadItem.create(in: context)
		item.url = firstFile.resolveURL
		item.transition(to: .draft)
		try DownloadItem.save(in: context)
		return item
	}

	func isPackageDownload(_ item: DownloadItem) -> Bool {
		packageManifest(for: item)?.isPackage == true
	}

	func isCatalogDownload(_ item: DownloadItem) -> Bool {
		packageManifest(for: item) != nil
	}

	func packageFileCount(for item: DownloadItem) -> Int? {
		packageManifest(for: item)?.files.count
	}

	func catalogArtifactName(for item: DownloadItem) -> String? {
		guard let relativePath = packageManifest(for: item)?.files.first?.relativePath else { return nil }
		if let packageComponent = relativePath.split(separator: "/").first(where: { $0.lowercased().hasSuffix(".mlpackage") }) {
			return String(packageComponent)
		}
		return URL(fileURLWithPath: relativePath).lastPathComponent
	}

	func packageFileProgressPublisher(for itemId: UUID?) -> AnyPublisher<PackageFileProgress, Never> {
		guard let itemId else {
			return Just(PackageFileProgress(completedFileCount: 0, totalFileCount: 0)).eraseToAnyPublisher()
		}

		return $activePackageDownloads
			.map { activePackageDownloads -> AnyPublisher<PackageFileProgress, Never> in
				guard let download = activePackageDownloads[itemId] else {
					return Just(PackageFileProgress(completedFileCount: 0, totalFileCount: 0)).eraseToAnyPublisher()
				}
				return download.$completedFileCount
					.combineLatest(download.$totalFileCount)
					.map { completedFileCount, totalFileCount in
						PackageFileProgress(completedFileCount: completedFileCount, totalFileCount: totalFileCount)
					}
					.eraseToAnyPublisher()
			}
			.switchToLatest()
			.removeDuplicates()
			.eraseToAnyPublisher()
	}

	private func packageManifest(for item: DownloadItem) -> PackageDownloadManifest? {
		if let manifest = packageManifests[item.entityId] {
			return manifest
		}
		guard let data = item.resumeData,
			  let manifest = try? JSONDecoder().decode(PackageDownloadManifest.self, from: data),
			  manifest.isValid else {
			return nil
		}
		packageManifests[item.entityId] = manifest
		return manifest
	}
    
    func progressPublisher(for itemId: UUID?) -> AnyPublisher<Double, Never> {
        guard let itemId else {
            return Just(0.0).eraseToAnyPublisher()
        }
        
		return Publishers.CombineLatest($activeDownloads, $activePackageDownloads)
			.map { activeDownloads, activePackageDownloads -> AnyPublisher<Double, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$progress
                        .eraseToAnyPublisher()
                }
				if let download = activePackageDownloads[itemId] {
					return download.$progress.eraseToAnyPublisher()
				}
				return Just(0.0).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func totalBytesWrittenPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never> {
        guard let itemId else {
            return Just(0).eraseToAnyPublisher()
        }
        
        return Publishers.CombineLatest($activeDownloads, $activePackageDownloads)
            .map { activeDownloads, activePackageDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesWritten
                        .eraseToAnyPublisher()
                }
				if let download = activePackageDownloads[itemId] {
					return download.$totalBytesWritten.eraseToAnyPublisher()
				}
				return Just(0).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func totalBytesExpectedPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never> {
        guard let itemId else {
            LoggingPolicy.error("Expected valid item id when getting download item progress", logger: .networking)
            return Just(0).eraseToAnyPublisher()
        }
        
        return Publishers.CombineLatest($activeDownloads, $activePackageDownloads)
            .map { activeDownloads, activePackageDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesExpected
                        .eraseToAnyPublisher()
                }
				if let download = activePackageDownloads[itemId] {
					return download.$totalBytesExpected.eraseToAnyPublisher()
				}
				return Just(0).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
	func downloadTapped(_ item: DownloadItem) {
		if isCatalogDownload(item), item.state == .downloading {
			return
		}

        switch item.state {
        case .notStarted, .failed, .cancelled, .imported, .importFailed: handleEvent(item, .start)
        case .downloading: handleEvent(item, .pause)
        case .paused: handleEvent(item, .start)
        case .complete: handleEvent(item, .start)
        }
    }
    
	func cancelTapped(_ item: DownloadItem) {
		if isCatalogDownload(item) {
			cancelPackageDownload(item)
			return
		}

        switch item.state {
        case .downloading, .paused: handleEvent(item, .cancel)
        default: break // a cancel action does not change anything at this state
        }
    }
    
    private func handleEvent(_ item: DownloadItem, _ event: Event) {
        switch (item.state, event) {
        case (.notStarted, .start), (.paused, .start), (.cancelled, .start), (.complete, .start), (.failed, .start),
            (.imported, .start), (.importFailed, .start):
            startDownload(item)
            
        case (.downloading, .pause):
            pauseDownload(item)
            
        case (.downloading, .cancel), (.paused, .cancel):
            cancelDownload(item)
            
        default:
            LoggingPolicy.warning("Invalid download state transition from \(item.state.rawValue) with event \(String(describing: event))", logger: .networking)
        }
    }
    
    private func transitionAndSave(_ item: DownloadItem, to newState: State) {
        item.state = newState
        saveDownloadContext()
    }
    
    private func saveDownloadContext() {
        let ctx = dataController.container.viewContext
        do {
            try DownloadItem.save(in: ctx)
        } catch {
            LoggingPolicy.error("Failed to save download context", error: error, logger: .networking)
        }
    }
    
    // MARK: Start/Cancel/Pause
    private func startDownload(_ item: DownloadItem) {
		if let manifest = packageManifest(for: item) {
			startPackageDownload(item, manifest: manifest)
			return
		}

        guard let url = item.url else {
            LoggingPolicy.error("Cannot start download: URL is nil for item \(item.entityId.uuidString)", logger: .networking)
            return
        }
        
        // Log host only: full URLs may carry signed query parameters / tokens (see LOGGING_GUIDE.md).
        LoggingPolicy.info("Starting download for item \(item.entityId.uuidString) from host \(url.host ?? "unknown")", logger: .networking)
        
        if item.lifeCycle == .draft {
            item.move()
        }
        
        let session: URLSession
        if let factory = sessionFactory {
            let configuration = URLSessionConfiguration.default
            let queue = OperationQueue()
            session = factory(configuration, delegateProxy, queue)
        } else if Self.shouldUseBackgroundSession {
            session = backgroundSession
        } else {
            session = foregroundSession
        }
        
        let downloadTask: URLSessionDownloadTask
        let entityId = item.entityId
        if let resumeData = item.resumeData {
            downloadTask = session.downloadTask(withResumeData: resumeData)
            item.resumeData = nil  // Clear after using
            LoggingPolicy.debug("Resuming download from paused state (loaded from CoreData)", logger: .networking)
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        
        downloadTask.taskDescription = item.entityId.uuidString
        // Register BEFORE resume(): delegate callbacks can fire immediately and
        // expect the activeDownloads entry to exist.
        activeDownloads[entityId] = ActiveDownload(task: downloadTask, itemId: entityId)
        downloadTask.resume()
        transitionAndSave(item, to: .downloading)
    }
    
	func cancelDownload(_ item: DownloadItem) {
		if isCatalogDownload(item) {
			cancelPackageDownload(item)
			return
		}

        let entityId = item.entityId
        guard let current = activeDownloads[entityId] else {
            // Cancelling from paused state (no active download)
            if item.state == .paused || item.state == .downloading {
                resetDownloadState(item)  // Also clears resumeData from CoreData
                transitionAndSave(item, to: .cancelled)
            }
            return
        }

        current.task.cancel()
    }

	func pauseDownload(_ item: DownloadItem) {
		guard isCatalogDownload(item) == false else { return }

        let entityId = item.entityId
        guard let download = activeDownloads[entityId] else { return }

        LoggingPolicy.debug("Pausing download for item \(entityId.uuidString)", logger: .networking)

        // Mark the intent BEFORE cancelling so sessionTaskDidComplete cannot mistake
        // this pause for a true cancel (the resume data lands asynchronously).
        download.isPausing = true

        // Sendable closure used by URLSession to deliver resume data.
        let storeResumeData: @Sendable (Data?) -> Void = { [weak self, entityId] data in
            guard let data else {
                LoggingPolicy.warning("Resume data not available when pausing download for item \(entityId.uuidString)", logger: .networking)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let item = DownloadItem.select(entityId, in: self.dataController.container.viewContext) {
                    item.resumeData = data
                    self.saveDownloadContext()
                    LoggingPolicy.debug("Resume data saved to CoreData for item \(entityId.uuidString)", logger: .networking)
                }
            }
        }

        download.task.cancel(byProducingResumeData: storeResumeData)
    }

	private func startPackageDownload(_ item: DownloadItem, manifest: PackageDownloadManifest) {
		guard activePackageDownloads[item.entityId] == nil else { return }

		if item.lifeCycle == .draft {
			item.move()
		}

		let entityId = item.entityId
		let activeDownload = ActivePackageDownload(itemId: entityId)
		activePackageDownloads[entityId] = activeDownload
		transitionAndSave(item, to: .downloading)

		LoggingPolicy.info("Starting package download for item \(entityId.uuidString) with \(manifest.files.count) files", logger: .networking)
		activeDownload.task = Task { [weak self, packageDownloader] in
			guard let self else { return }
			do {
				let events = await packageDownloader.events(for: manifest.files)
				for try await event in events {
					guard Task.isCancelled == false else { return }
					switch event {
					case .progress(let progress):
						self.updatePackageDownloadProgress(progress, itemId: entityId)
					case .finished(let packageURL):
						self.handlePackageDownloadCompletion(itemId: entityId, result: .success(packageURL))
					}
				}
			} catch {
				guard Task.isCancelled == false else { return }
				self.handlePackageDownloadCompletion(itemId: entityId, result: .failure(error))
			}
		}
	}

	private func cancelPackageDownload(_ item: DownloadItem) {
		let entityId = item.entityId
		activePackageDownloads[entityId]?.task?.cancel()
		activePackageDownloads.removeValue(forKey: entityId)

		guard item.state == .downloading || item.state == .paused else { return }
		resetPackageDownloadState(item)
		transitionAndSave(item, to: .cancelled)
	}

	private func updatePackageDownloadProgress(_ progress: CatalogPackageDownloadProgress, itemId: UUID) {
		guard let activeDownload = activePackageDownloads[itemId],
			  let item = DownloadItem.select(itemId, in: dataController.container.viewContext) else {
			return
		}

		activeDownload.progress = progress.fractionCompleted
		activeDownload.totalBytesWritten = Int(progress.downloadedBytes)
		activeDownload.totalBytesExpected = Int(progress.expectedBytes ?? 0)
		activeDownload.completedFileCount = progress.completedFileCount
		activeDownload.totalFileCount = progress.totalFileCount
		persistPackageDownloadState(from: activeDownload, to: item)
	}

	private func handlePackageDownloadCompletion(itemId: UUID, result: Result<URL, Error>) {
		guard let activeDownload = activePackageDownloads[itemId] else { return }
		defer { activePackageDownloads.removeValue(forKey: itemId) }

		guard let item = DownloadItem.select(itemId, in: dataController.container.viewContext) else {
			LoggingPolicy.warning("Package download item not found for \(itemId.uuidString)", logger: .networking)
			return
		}

		switch result {
		case .success(let packageURL):
			do {
				let stagingDirectory = packageStagingDirectory(for: packageURL, manifest: packageManifest(for: item))
					?? packageURL.deletingLastPathComponent()
				let targetURL = try FileManager.moveModelToDocuments(from: packageURL, configurationId: itemId)
				try? FileManager.default.removeItem(at: stagingDirectory)
				item.file_ = try targetURL.relativePath(from: DownloadItem.rootDirectory)
				activeDownload.totalBytesExpected = Self.completedExpectedBytes(
					written: activeDownload.totalBytesWritten,
					expected: activeDownload.totalBytesExpected
				)
				activeDownload.progress = 1
				persistPackageDownloadState(from: activeDownload, to: item)
				transitionAndSave(item, to: .complete)
				LoggingPolicy.info("Package download successfully saved", logger: .networking)
			} catch {
				LoggingPolicy.error("Could not store downloaded package", error: error, logger: .networking)
				item.error = L10n.Catalog.Download.error
				persistPackageDownloadState(from: activeDownload, to: item)
				transitionAndSave(item, to: .failed)
			}
		case .failure(let error):
			LoggingPolicy.error("Package download failed", error: error, logger: .networking)
			item.error = L10n.Catalog.Download.error
			persistPackageDownloadState(from: activeDownload, to: item)
			transitionAndSave(item, to: .failed)
		}
	}

	private func packageStagingDirectory(for packageURL: URL, manifest: PackageDownloadManifest?) -> URL? {
		guard let relativePath = manifest?.files.first?.relativePath else { return nil }
		let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
		guard let packageIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".mlpackage") }) else {
			return nil
		}

		return (0...packageIndex).reduce(packageURL) { directory, _ in
			directory.deletingLastPathComponent()
		}
	}
    
    // MARK: URLSession delegate forwarding endpoints (called by the proxy)
    func sessionTaskDidComplete(session: URLSession, task: any TaskIdentifiable, error: Error?) {
        guard
            let idString = task.taskDescription,
            let id = UUID(uuidString: idString)
        else {
            LoggingPolicy.warning("Download task completed but identifier not found or invalid", logger: .networking)
            return
        }

        // The in-memory entry may be missing (background relaunch, callback ordering);
        // the DownloadItem in Core Data is the source of truth.
        let download = activeDownloads[id]
        defer { activeDownloads.removeValue(forKey: id) }

        guard let item = DownloadItem.select(id, in: dataController.container.viewContext) else {
            LoggingPolicy.warning("Download item not found in Core Data for \(id.uuidString)", logger: .networking)
            return
        }

        guard let nsError = error as NSError? else {
            // Success: file move and the .complete transition happen in handleDownloadCompletion.
            // Never reset state here — doing so could overwrite an already-completed item.
            return
        }

        switch nsError.code {
        case NSURLErrorCancelled:
            LoggingPolicy.debug("Download cancelled for item \(id.uuidString)", logger: .networking)
            // isPausing is the authoritative signal (set synchronously before the cancel);
            // resumeData is the fallback for completions delivered after a relaunch,
            // when no in-memory ActiveDownload entry exists.
            if download?.isPausing == true || item.resumeData != nil {
                // Pausing: preserve progress state (resume data is saved separately)
                if let download {
                    Self.persistDownloadState(from: download, to: item)
                }
                transitionAndSave(item, to: .paused)
            } else {
                // True cancel: reset progress and clear state
                resetDownloadState(item)
                transitionAndSave(item, to: .cancelled)
            }
        case NSURLErrorNotConnectedToInternet:
            LoggingPolicy.error("Download failed due to no internet connection for item \(id.uuidString)", logger: .networking)
            item.error = "Check your connection and restart download. " + nsError.localizedDescription
            if let download {
                Self.persistDownloadState(from: download, to: item)
            }
            transitionAndSave(item, to: .failed)
        default:
            // Unknown errors previously left the item stuck in .downloading with no task.
            LoggingPolicy.error("Download error \(nsError.code) for item \(id.uuidString): \(nsError.localizedDescription)", logger: .networking)
            item.error = nsError.localizedDescription
            if let download {
                Self.persistDownloadState(from: download, to: item)
            }
            transitionAndSave(item, to: .failed)
        }
    }
    
    func sessionDownloadDidWriteData(session: URLSession,
                                     downloadTask: any TaskIdentifiable,
                                     bytesWritten: Int64,
                                     totalBytesWritten: Int64,
                                     totalBytesExpectedToWrite: Int64) {
        guard
            let idString = downloadTask.taskDescription,
            let id = UUID(uuidString: idString),
            let download = activeDownloads[id]
        else {
            LoggingPolicy.error("Download task identifier not defined or invalid during progress update", logger: .networking)
            return
        }
        
        download.totalBytesWritten = Int(totalBytesWritten)
        // totalBytesExpectedToWrite is -1 when the size is unknown — avoid negative progress.
        if totalBytesExpectedToWrite > 0 {
            download.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            download.totalBytesExpected = Int(totalBytesExpectedToWrite)
        }
    }
    
    // MARK: Completion handling
    @MainActor
    func handleDownloadCompletion(itemId: UUID, fileURL: Result<URL, Error>) {
        // The in-memory entry may be missing (e.g. the app was relaunched to handle
        // background session events) — the DownloadItem in Core Data is the source of
        // truth. Requiring the entry here used to silently lose completed downloads.
        let download = activeDownloads[itemId]
        defer { activeDownloads.removeValue(forKey: itemId) }

        guard let item = DownloadItem.select(itemId, in: dataController.container.viewContext) else {
            LoggingPolicy.warning("Download item not found in Core Data for \(itemId.uuidString)", logger: .networking)
            return
        }

        switch fileURL {
        case .success(let targetPath):
            do {
                let relativePath = try targetPath.relativePath(from: DownloadItem.rootDirectory)
                item.file_ = relativePath
                if let download {
					download.totalBytesExpected = Self.completedExpectedBytes(
						written: download.totalBytesWritten,
						expected: download.totalBytesExpected
					)
					download.progress = 1
                    Self.persistDownloadState(from: download, to: item)
                }
                transitionAndSave(item, to: .complete)
                LoggingPolicy.info("Download successfully saved", logger: .networking)
            } catch {
                // The moved file cannot be referenced; remove it so it doesn't orphan,
                // and mark the item failed so the user can retry.
                LoggingPolicy.error("Could not construct relative path for downloaded model", error: error, logger: .networking)
                try? FileManager.default.removeItem(at: targetPath)
                item.error = error.localizedDescription
                transitionAndSave(item, to: .failed)
            }

        case .failure(let error):
            LoggingPolicy.error("Download completion failed", error: error, logger: .networking)
            item.error = error.localizedDescription
            if let download {
                Self.persistDownloadState(from: download, to: item)
            }
            transitionAndSave(item, to: .failed)
        }

        item.resumeData = nil  // Clear any stale resume data
    }
    
    static private func createDirectoryIfNeeded(at path: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            try fm.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private static func persistDownloadState(from download: ActiveDownload, to item: DownloadItem) {
        item.progress = download.progress
        item.totalBytesWritten = Int64(download.totalBytesWritten)
        item.totalBytesExpectedToWrite = Int64(download.totalBytesExpected)
    }

	private func persistPackageDownloadState(from download: ActivePackageDownload, to item: DownloadItem) {
		item.progress = download.progress
		item.totalBytesWritten = Int64(download.totalBytesWritten)
		item.totalBytesExpectedToWrite = Int64(download.totalBytesExpected)
	}

	/// A package manifest remains attached to the item after cancellation so Restart continues to
	/// use the multi-file job rather than accidentally treating an internal package file as a URL.
	private func resetPackageDownloadState(_ item: DownloadItem) {
		item.progress = 0.0
		item.totalBytesWritten = 0
		item.totalBytesExpectedToWrite = 0
		item.file_ = nil
		item.error = nil
	}
    
    /// Resets download progress state to initial values (used when cancelling)
    private func resetDownloadState(_ item: DownloadItem) {
        item.progress = 0.0
        item.totalBytesWritten = 0
        item.totalBytesExpectedToWrite = 0
        item.file_ = nil
        item.error = nil
        item.resumeData = nil
    }

    // MARK: - Test helpers
    /// Injects resume data for a given item ID to simulate a paused state in tests.
    func _testInjectResumeData(for id: UUID, data: Data = Data()) {
        guard let item = DownloadItem.select(id, in: dataController.container.viewContext) else { return }
        item.resumeData = data
        saveDownloadContext()
    }
}

@MainActor
extension Downloader: @MainActor ModelProvider {
    func result(_ error: ModelProviderError, id: UUID) {
        guard let item = DownloadItem.select(id, in: dataController.container.viewContext)
        else { return }

        switch error {
        case .importSucceeded:
            transitionAndSave(item, to: .imported)
        case .importFailed:
            transitionAndSave(item, to: .importFailed)
        }
    }
}

extension DownloadItem: CoreDataManagableWithState {
    func validationReport() -> CoreDataManagableValidationReport {
        guard lifeCycle == .draft || lifeCycle == .ready else { return .init(issues: nil) }

        var issues: [CoreDataManagableValidationIssue] = []

        // Only validate if download has started or completed
        guard state != .notStarted else { return .init(issues: nil) }

        // The model file only exists once the download finished. Requiring it for
        // in-flight states (.downloading/.paused/...) made validateForUpdate throw on
        // every mid-download save — including the resume-data persistence on pause.
        // .importFailed also implies a finished download (the UI offers retry from it).
        if [.complete, .imported, .importFailed].contains(state),
           file.isNil || file?.absoluteString.isEmpty == true {
            issues.append(.init(key: "file", message: "Model file is required."))
        }

        if url.isNil || url?.absoluteString.isEmpty == true {
            issues.append(.init(key: "url", message: "Model's url is required."))
        }

        return .init(issues: issues)
    }
}

// Add the validations using the core data's api:
extension DownloadItem {
    public override func validateForInsert() throws {
        try super.validateForInsert()
        if lifeCycle == .ready {
            try throwIfInvalid()
        }
    }
    
    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        if lifeCycle == .ready {
            try throwIfInvalid()
        }
    }
}

extension DownloadItem: CoreDataManageable {
    static func create(in context: NSManagedObjectContext) -> Self {
        let newItem = Self(context: context)
        do {
            try DownloadItem.save(in: context)
        } catch {
            LoggingPolicy.error("Failed to save newly created download item", error: error, logger: .networking)
        }
        return newItem
    }
    
    static func delete(_ entity: DownloadItem, in context: NSManagedObjectContext, deleteModel: Bool) {
        if deleteModel.enabled, let modelPath = entity.file {
            if FileManager.default.fileExists(atPath: modelPath.path) {
                do {
                    try FileManager.default.removeItem(at: modelPath)
                    LoggingPolicy.debug("Model file deleted for download item \(entity.entityId.uuidString)", logger: .networking)
                } catch {
                    LoggingPolicy.error("Error deleting model file for download item \(entity.entityId.uuidString)", error: error, logger: .networking)
                    DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteDownloadModel", "itemId": entity.entityId.uuidString])
                }
            }
        }
        DownloadItem.delete(entity, in: context)
    }
    
    func doesModelFileExist() -> Bool {
        guard let modelPath = file else {
            LoggingPolicy.warning("Expected file value in download item but it is nil", logger: .networking)
            return false
        }
        return FileManager.default.fileExists(atPath: modelPath.path)
    }
}

extension DownloadItem {
    typealias State = Downloader.State
    
    public static var rootDirectory: FileManager.SearchPathDirectory { .documentDirectory }

    public var file: URL? {
        guard let file_ else { return nil }
        return try? file_.completePath(to: DownloadItem.rootDirectory, isDirectory: false)
    }
    
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
            case State.complete.id: return .complete
            case State.imported.id: return .imported
            case State.importFailed.id: return .importFailed
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
