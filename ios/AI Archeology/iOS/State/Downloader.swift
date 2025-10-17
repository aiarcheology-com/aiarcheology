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

enum DownloaderError: Error {
    case invalidObjectInQueue
    case invalidStateInQueue
}

final class ActiveDownload: Identifiable, Comparable, Hashable, ObservableObject {
    let itemId: UUID
    @Published var progress: Double = 0.0
    @Published var totalBytesWritten: Int = 0
    @Published var totalBytesExpected: Int = 0
    
    var id: UUID {
        return itemId
    }
    let started: Date = .now
    weak var task: URLSessionDownloadTask?
    
    init(task: URLSessionDownloadTask, itemId: UUID) {
        self.task = task
        self.itemId = itemId
    }
    
    static func < (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.started < rhs.started
    }
    
    static func == (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public class Downloader: NSObject, ObservableObject {
    public enum State: String, CaseIterable, Identifiable {
        case notStarted = "Not started"
        case downloading = "Downloading"
        case paused = "Paused"
        case cancelled = "Cancelled"
        case failed = "Failed"
        case complete = "Complete"
        case imported = "Imported"
        
        public var id: String { self.rawValue }
    }
    
    enum Event {
        case start
        case pause
        case cancel
    }
    
    unowned var appState: AppState
    @Published private(set) var activeDownloads: [UUID: ActiveDownload] = [:]
    private var pausedDownloads: [UUID: Data] = [:]
    
    let networkMonitor = NWPathMonitor()
    
    init(appState: AppState) {
        self.appState = appState
        
        super.init()
        self.networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            switch path.status {
            case .satisfied: break
            default:
                activeDownloads.values.forEach { download in
                    // Fetch the managed object to update error state
                    if let item = DownloadItem.select(download.id, in: self.appState.dataController.container.viewContext) {
                        item.error = "There are issues with your \(self.getNetworkType(path)) connection. The download has been paused."
                        self.handleEvent(item, .pause)
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
    
    func progressPublisher(for itemId: UUID?) -> AnyPublisher<Double, Never> {
        guard let itemId else {
            return Empty<Double, Never>(completeImmediately: true).eraseToAnyPublisher()
        }
        
        // Map the activeDownloads dictionary into a publisher of the matching ActiveDownload's $progress
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Double, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$progress
                        .eraseToAnyPublisher()
                } else {
                    return Empty<Double, Never>(completeImmediately: true).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func totalBytesWrittenPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never> {
        guard let itemId else {
            return Empty<Int, Never>(completeImmediately: true).eraseToAnyPublisher()
        }
        
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesWritten
                        .eraseToAnyPublisher()
                } else {
                    return Empty<Int, Never>(completeImmediately: true).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func totalBytesExpectedPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never> {
        guard let itemId else {
            assert(false, "[DL] Expecting a valid item id when getting the progress of the download item.")
            return Empty<Int, Never>(completeImmediately: true).eraseToAnyPublisher()
        }
        
        return $activeDownloads
            .map { activeDownloads -> AnyPublisher<Int, Never> in
                if let download = activeDownloads[itemId] {
                    return download.$totalBytesExpected
                        .eraseToAnyPublisher()
                } else {
                    return Empty<Int, Never>(completeImmediately: true).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    
    func downloadTapped(_ item: DownloadItem) {
        switch item.state {
        case .notStarted, .failed, .cancelled, .imported: handleEvent(item, .start)
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
            (.imported, .start): // TODO: Is it ok to let the user download the file again, when it is already imported?
            startDownload(item)
            
        case (.downloading, .pause):
            pauseDownload(item)
            
        case (.downloading, .cancel), (.paused, .cancel):
            cancelDownload(item)
            
        default:
            assert(false, "Invalid transition from \(item.state) with event \(event)")
        }
    }
    
    private func transitionAndSave(_ item: DownloadItem, to newState: State) {
        item.state = newState
        saveDownloadContext()
    }
}

extension Downloader: ModelProvider {
    func result(_ error: ModelProviderError, id: UUID) {
        guard let item = DownloadItem.select(id, in: appState.dataController.container.viewContext)
        else { return }
        
        switch error {
        case .importSucceeded:
            transitionAndSave(item, to: .imported)
        case .importFailed:
            break
        }
    }
}

extension Downloader: URLSessionDownloadDelegate  {
    private func saveDownloadContext() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let downloadContext = self.appState.dataController.container.viewContext
            DownloadItem.save(in: downloadContext)
        }
    }
    
    private func startDownload(_ item: DownloadItem) {
        guard let url = item.url
        else {
            assert(false, "[DL] There must be a valid url before the download starts.")
            return
        }
        
        let configuration = URLSessionConfiguration.default
        let operationQueue = OperationQueue()
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        
        let downloadTask: URLSessionDownloadTask
        if
            let entityId = item.entityId,
            let pausedData = pausedDownloads[entityId] {
            downloadTask = session.downloadTask(withResumeData: pausedData)
            pausedDownloads.removeValue(forKey: entityId)
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        
        downloadTask.taskDescription = item.entityId?.uuidString
        downloadTask.resume()
        transitionAndSave(item, to: .downloading)
        
        DispatchQueue.main.async { [weak self] in
            guard let self, let entityId = item.entityId else { return }
            let download = ActiveDownload(task: downloadTask, itemId: entityId)
            self.activeDownloads[entityId] = download
        }
    }
    
    func cancelDownload(_ item: DownloadItem) {
        guard let entityId = item.entityId else { return }
        
        guard let download = activeDownloads[entityId] else {
            // There is no download active.
            switch item.state {
            case .paused, .downloading: // TODO: Better handling from the paused, and terminated downloads. Reset the hanging states.
                transitionAndSave(item, to: .notStarted)
            default:
                break
            }
            
            return
        }
        
        guard let task = download.task
        else { // locate the task using URLSession
            URLSession.shared.getTasksWithCompletionHandler { sessionDatas, uploadTasks, downloadTasks in
                download.task = downloadTasks.first(where: { $0.taskDescription ?? "" == download.id.uuidString})
                guard let task = download.task else { return }
                task.cancel()
            }
            return
        }
        
        task.cancel()
    }
    
    func pauseDownload(_ item: DownloadItem) {
        guard let entityId = item.entityId else { return }
        
        guard let download = activeDownloads[entityId] else {
            return
        }
        
        func produceResumeDataByCancellingTask(_ sessionTask: URLSessionDownloadTask) {
            sessionTask.cancel { [weak self] data in
                guard let self else {
                    assert(false, "[DL] The Downloader has been unloaded before the task was succesfully paused.")
                    return
                }
                
                guard let data else { // TODO: find out, why the data are not sometimes available
                    // assert(false, "[DL] The data to resume the download are not available.")
                    return
                }
                
                pausedDownloads[entityId] = data
            }
        }
        
        if let task = download.task { // TODO: find out, why the task is beeing dealocated
            produceResumeDataByCancellingTask(task)
        }
        else { // fallback, search for the task using stored task taskDescription
            URLSession.shared.getTasksWithCompletionHandler { sessionDatas, uploadTasks, downloadTasks in
                download.task = downloadTasks.first(where: { $0.taskDescription ?? "" == download.id.uuidString})
                guard let task = download.task else { return }
                produceResumeDataByCancellingTask(task)
            }
        }
    }
    
    private func handleDownloadCompletion(for download: ActiveDownload, location: URL) {
        guard let targetDirectory = FileManager.deepConfigurationDirectory(id: download.id)
        else {
            assert(false, "[DL] Document directory could not be composed.")
            return
        }
        
        // Fetch the managed object to get URL and update properties
        guard let item = DownloadItem.select(download.id, in: appState.dataController.container.viewContext),
              let url = item.url
        else {
            assert(false, "[DL] The item's url property is not initialised.")
            return
        }
        
        do {
            try Self.createDirectoryIfNeeded(at: targetDirectory)
            let fileName = url.lastPathComponent
            let targetPath = targetDirectory.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: targetPath.path) {
                try FileManager.default.removeItem(at: targetPath)
            }
            
            try FileManager.default.moveItem(at: location, to: targetPath)
            
            guard let relativePath = try? targetPath.relativePath(from: DownloadItem.rootDirectory) else {
                assert(false, "Model file is required.")
                return
            }
            
            item.file_ = relativePath
            // Save final progress/bytes values to Core Data for non-active display
            Downloader.persistDownloadState(from: download, to: item)
            transitionAndSave(item, to: .complete)
            
        } catch let error {
            print("error: \(error)")
            item.error = error.localizedDescription
            // Save final progress/bytes values even on failure
            Downloader.persistDownloadState(from: download, to: item)
            transitionAndSave(item, to: .failed)
        }
        
        pausedDownloads.removeValue(forKey: download.id)
        
        DispatchQueue.main.async { [weak self] in
            self?.activeDownloads.removeValue(forKey: download.id)
        }
    }
    
    static private func createDirectoryIfNeeded(at path: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path.path) {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    // MARK: - URLSessionDownloadDelegate Methods
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard
            let entityIdString = task.taskDescription,
            let entityId = UUID(uuidString: entityIdString),
            let download = self.activeDownloads[entityId]
        else {
            // assert(false, "The task identifier has to be defined before the download can succeed.")
            
            // Fallback to the initial state. User can still delete the download item in the list.
            DispatchQueue.main.async { [weak self] in
                if    let self,
                      let entityIdString = task.taskDescription,
                      let entityId = UUID(uuidString: entityIdString),
                      let item = DownloadItem.select(entityId, in: self.appState.dataController.container.viewContext) {
                    transitionAndSave(item, to: .notStarted)
                }
            }
            return
        }
        
        // Fetch the managed object to update state and error
        guard let item = DownloadItem.select(download.id, in: appState.dataController.container.viewContext)
        else {
            DispatchQueue.main.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: download.id)
            }
            return
        }
        
        if    // The task has been cancelled or paused
            let error = error as? NSError {
            switch error.code {
            case NSURLErrorCancelled:
                // Save current progress/bytes values before transitioning state
                Downloader.persistDownloadState(from: download, to: item)
                if pausedDownloads[entityId].isNotNil {
                    transitionAndSave(item, to: .paused)
                } else
                {
                    transitionAndSave(item, to: .cancelled)
                }
            case NSURLErrorNotConnectedToInternet:
                item.error = "Check your connection and restart download. " + error.localizedDescription
                // Save current progress/bytes values before transitioning state
                Downloader.persistDownloadState(from: download, to: item)
                transitionAndSave(item, to: .failed)
                
            default: break
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.activeDownloads.removeValue(forKey: download.id)
            }
            
            return
        }
        
        guard let error = error else {
            return
        }
        
        item.error = error.localizedDescription
        // Save current progress/bytes values before transitioning state
        Downloader.persistDownloadState(from: download, to: item)
        transitionAndSave(item, to: .failed)
        
        let userInfo = (error as NSError).userInfo
        if let resumeData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            pausedDownloads[entityId] = resumeData
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.activeDownloads.removeValue(forKey: download.id)
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard
            let entityIdString = downloadTask.taskDescription,
            let entityId = UUID(uuidString: entityIdString),
            let download = self.activeDownloads[entityId]
        else {
            assert(false, "The task identifier has to be defined before the download can succeed.")
            return
        }
        
        // Update ActiveDownload's local primitives only - do NOT write to Core Data
        // This breaks the tight feedback loop that causes CPU spikes on iOS 16
        DispatchQueue.main.async {
            download.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            download.totalBytesWritten = Int(totalBytesWritten)
            download.totalBytesExpected = Int(totalBytesExpectedToWrite)
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard
            let entityIdString = downloadTask.taskDescription,
            let entityId = UUID(uuidString: entityIdString),
            let download = self.activeDownloads[entityId]
        else {
            assert(false, "The task identifier has to be defined before the download can succeed.")
            return
        }
        
        handleDownloadCompletion(for: download, location: location)
    }
    
    private static func persistDownloadState(from download: ActiveDownload, to item: DownloadItem) {
        // Copy current values from the ActiveDownload's managed item to ensure consistency.
        // This centralizes the three assignments in one place to avoid duplication.
        item.progress = download.progress
        item.totalBytesWritten = Int64(download.totalBytesWritten)
        item.totalBytesExpectedToWrite = Int64(download.totalBytesExpected)
    }
}

extension DownloadItem: CoreDataManageable {
    static func create(in context: NSManagedObjectContext) -> Self {
        let newItem = Self(context: context)
        newItem.entityId = UUID()
        DownloadItem.save(in: context)
        return newItem
    }
    
    static func delete(_ entity: DownloadItem, in context: NSManagedObjectContext, deleteModel: Bool) {
        if deleteModel.enabled, let modelPath = entity.file {
            if FileManager.default.fileExists(atPath: modelPath.path) {
                do {
                    try FileManager.default.removeItem(at: modelPath)
                } catch let error {
                    print("[DI] There was an error during the model file deletion \(entity.entityId?.uuidString ?? "unknown"): \(error)")
                }
            }
        }
        DownloadItem.delete(entity, in: context)
    }
    
    func doesModelFileExist() -> Bool {
        guard let modelPath = file else {
            assert(false, "[DI] Expecting a file value in the download item, but it is nil.")
            return false
        }
        return FileManager.default.fileExists(atPath: modelPath.path)
    }
}

extension DownloadItem {
    typealias State = Downloader.State
    
    public static var rootDirectory: FileManager.SearchPathDirectory {
        get { .documentDirectory }
    }
    
    public var file: URL? {
        get {
            guard let file_ else { return nil}
            return try? file_.completePath(to: DownloadItem.rootDirectory, isDirectory: false)
        }
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
        guard readyToValidate.enabled else { return }
        
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
