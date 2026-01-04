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
    weak var task: (any DownloadTaskProtocol)?
    
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
    
    let dataController: DataController
    @Published private(set) var activeDownloads: [UUID: ActiveDownload] = [:]
    private var pausedDownloads: [UUID: Data] = [:]
    
    private let networkMonitor = NWPathMonitor()
    private lazy var delegateProxy: DownloaderSessionDelegateProxy = DownloaderSessionDelegateProxy(owner: self)
    
    // Test hook
    var sessionFactory: ((URLSessionConfiguration, URLSessionDelegate?, OperationQueue?) -> URLSession)?
        
    init(dataController: DataController) {
        self.dataController = dataController
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
        Downloader.current = self
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
    
    func progressPublisher(for itemId: UUID?) -> AnyPublisher<Double, Never> {
        guard let itemId else {
            return Just(0.0).eraseToAnyPublisher()
        }
        
        // Map the activeDownloads dictionary into a publisher of the matching ActiveDownload's $progress
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Double, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$progress
                        .eraseToAnyPublisher()
                } else {
                    return Just(0.0).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func totalBytesWrittenPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never> {
        guard let itemId else {
            return Just(0).eraseToAnyPublisher()
        }
        
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesWritten
                        .eraseToAnyPublisher()
                } else {
                    return Just(0).eraseToAnyPublisher()
                }
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
        
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesExpected
                        .eraseToAnyPublisher()
                } else {
                    return Just(0).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func downloadTapped(_ item: DownloadItem) {
        switch item.state {
        case .notStarted, .failed, .cancelled, .imported, .importFailed: handleEvent(item, .start)
        case .downloading: handleEvent(item, .pause)
        case .paused: handleEvent(item, .start)
        case .complete: handleEvent(item, .start)
        }
    }
    
    func cancelTapped(_ item: DownloadItem) {
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
        DownloadItem.save(in: ctx)
    }
    
    // MARK: Start/Cancel/Pause
    private func startDownload(_ item: DownloadItem) {
        guard let url = item.url else {
            LoggingPolicy.error("Cannot start download: URL is nil for item \(item.entityId.uuidString)", logger: .networking)
            return
        }
        
        LoggingPolicy.info("Starting download for item \(item.entityId.uuidString) from \(url.absoluteString)", logger: .networking)
        
        if item.lifeCycle == .draft {
            item.move()
        }
        
        let configuration = URLSessionConfiguration.default
        let queue = OperationQueue()
        let session: URLSession
        if let factory = sessionFactory {
            session = factory(configuration, delegateProxy, queue)
        } else {
            session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: queue)
        }
        
        let downloadTask: URLSessionDownloadTask
        let entityId = item.entityId
        if let pausedData = pausedDownloads[entityId] {
            downloadTask = session.downloadTask(withResumeData: pausedData)
            pausedDownloads.removeValue(forKey: entityId)
            LoggingPolicy.debug("Resuming download from paused state", logger: .networking)
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        
        downloadTask.taskDescription = item.entityId.uuidString
        downloadTask.resume()
        transitionAndSave(item, to: .downloading)
        
        activeDownloads[entityId] = ActiveDownload(task: downloadTask, itemId: entityId)
    }
    
    func cancelDownload(_ item: DownloadItem) {
        let entityId = item.entityId
        guard let current = activeDownloads[entityId] else {
            // Cancelling from paused state (no active download)
            if item.state == .paused || item.state == .downloading {
                resetDownloadState(item)
                pausedDownloads.removeValue(forKey: entityId)
                transitionAndSave(item, to: .cancelled)
            }
            return
        }
        
        if let task = current.task {
            task.cancel()
            return
        }
        
        // Fallback: locate the task using URLSession
        URLSession.shared.getTasksWithCompletionHandler { _, _, downloadTasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeDownloads[entityId]?.task = downloadTasks.first { $0.taskDescription == entityId.uuidString }
                self.activeDownloads[entityId]?.task?.cancel()
            }
        }
    }
    
    func pauseDownload(_ item: DownloadItem) {
        let entityId = item.entityId
        guard let download = activeDownloads[entityId] else { return }
        
        LoggingPolicy.debug("Pausing download for item \(entityId.uuidString)", logger: .networking)
        
        // Sendable closure used by URLSession to deliver resume data.
        let storeResumeData: @Sendable (Data?) -> Void = { [entityId] data in
            guard let data else {
                LoggingPolicy.warning("Resume data not available when pausing download for item \(entityId.uuidString)", logger: .networking)
                return
            }
            Task { @MainActor in
                Downloader.current?.pausedDownloads[entityId] = data
            }
        }
        
        if let task = download.task {
            task.cancel(byProducingResumeData: storeResumeData)
            return
        }
        
        // Fallback: locate the task via URLSession and then cancel for resume data.
        URLSession.shared.getTasksWithCompletionHandler { _, _, downloadTasks in
            downloadTasks.first { $0.taskDescription == entityId.uuidString }?
                .cancel(byProducingResumeData: storeResumeData)
        }
    }
    
    // MARK: URLSession delegate forwarding endpoints (called by the proxy)
    func sessionTaskDidComplete(session: URLSession, task: any TaskIdentifiable, error: Error?) {
        guard
            let idString = task.taskDescription,
            let id = UUID(uuidString: idString),
            let download = activeDownloads[id]
        else {
            LoggingPolicy.warning("Download task completed but identifier not found or invalid", logger: .networking)
            if
                let idString = task.taskDescription,
                let id = UUID(uuidString: idString),
                let item = DownloadItem.select(id, in: dataController.container.viewContext) {
                // Only reset if it's not in a terminal state (success/failure already handled)
                if item.state == Downloader.State.downloading || item.state == Downloader.State.paused {
                    transitionAndSave(item, to: Downloader.State.notStarted)
                }
            }
            return
        }
        
        guard let item = DownloadItem.select(download.id, in: dataController.container.viewContext) else {
            LoggingPolicy.warning("Download item not found in Core Data for \(download.id.uuidString)", logger: .networking)
            activeDownloads.removeValue(forKey: download.id)
            return
        }
        
        if let nsError = error as NSError? {
            switch nsError.code {
            case NSURLErrorCancelled:
                LoggingPolicy.debug("Download cancelled for item \(download.id.uuidString)", logger: .networking)
                if pausedDownloads[id] != nil {
                    // Pausing: preserve progress state
                    Self.persistDownloadState(from: download, to: item)
                    transitionAndSave(item, to: .paused)
                } else {
                    // True cancel: reset progress and clear state
                    resetDownloadState(item)
                    transitionAndSave(item, to: .cancelled)
                }
            case NSURLErrorNotConnectedToInternet:
                LoggingPolicy.error("Download failed due to no internet connection for item \(download.id.uuidString)", logger: .networking)
                item.error = "Check your connection and restart download. " + nsError.localizedDescription
                Self.persistDownloadState(from: download, to: item)
                transitionAndSave(item, to: .failed)
            default:
                LoggingPolicy.error("Download error \(nsError.code) for item \(download.id.uuidString): \(nsError.localizedDescription)", logger: .networking)
            }
            activeDownloads.removeValue(forKey: download.id)
            return
        }
        
        // Success path - item already handled by handleDownloadCompletion
        // Just clean up the activeDownload if still present
        activeDownloads.removeValue(forKey: download.id)
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
        
        download.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        download.totalBytesWritten = Int(totalBytesWritten)
        download.totalBytesExpected = Int(totalBytesExpectedToWrite)
    }
    
    // MARK: Completion handling
    @MainActor
    func handleDownloadCompletion(itemId: UUID, fileURL: Result<URL, Error>) {
        guard let download = activeDownloads[itemId],
              let item = DownloadItem.select(itemId, in: dataController.container.viewContext)
        else {
            LoggingPolicy.warning("Download item not found in Core Data for \(itemId.uuidString)", logger: .networking)
            activeDownloads.removeValue(forKey: itemId)
            return
        }
        
        switch fileURL {
        case .success(let targetPath):
            do {
                guard let relativePath = try? targetPath.relativePath(from: DownloadItem.rootDirectory) else {
                    LoggingPolicy.error("Could not construct relative path for downloaded model", logger: .networking)
                    return
                }
                
                item.file_ = relativePath
                Self.persistDownloadState(from: download, to: item)
                transitionAndSave(item, to: .complete)
                LoggingPolicy.info("Download successfully saved", logger: .networking)
            }
            
        case .failure(let error):
            LoggingPolicy.error("Download completion failed", error: error, logger: .networking)
            item.error = error.localizedDescription
            Self.persistDownloadState(from: download, to: item)
            transitionAndSave(item, to: .failed)
        }
        
        pausedDownloads.removeValue(forKey: itemId)
        activeDownloads.removeValue(forKey: itemId)
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
    
    /// Resets download progress state to initial values (used when cancelling)
    private func resetDownloadState(_ item: DownloadItem) {
        item.progress = 0.0
        item.totalBytesWritten = 0
        item.totalBytesExpectedToWrite = 0
        item.file_ = nil
        item.error = nil
    }
    
    // Optional: global access if needed by closures
    static weak var current: Downloader?

    // MARK: - Test helpers
    /// Injects resume data for a given item ID to simulate a paused state in tests.
    func _testInjectResumeData(for id: UUID, data: Data = Data()) {
        pausedDownloads[id] = data
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
        
        if file.isNil || file?.absoluteString.isEmpty == true {
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
        try throwIfInvalid()
    }
    
    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        try throwIfInvalid()
    }
}

extension DownloadItem: CoreDataManageable {
    static func create(in context: NSManagedObjectContext) -> Self {
        let newItem = Self(context: context)
        DownloadItem.save(in: context)
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
