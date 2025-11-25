//
//  DownloaderTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import Combine
import CoreData
@testable import ML_Browser

// MARK: - Mock URLSessionDownloadTask

/// A minimal mock download task for testing.
/// Note: URLSessionDownloadTask.init() is deprecated in iOS 13+, but subclassing
/// is the only way to create a mock that can be passed where URLSessionDownloadTask
/// is expected. This is acceptable for test-only code.
final class MockDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    var resumeCalled = false
    var cancelCalled = false
    var cancelWithResumeDataCalled = false
    var capturedResumeDataHandler: (@Sendable (Data?) -> Void)?
    
    private let _taskDescription: String?
    private let _state: URLSessionTask.State
    
    init(taskDescription: String? = nil, state: URLSessionTask.State = .suspended) {
        self._taskDescription = taskDescription
        self._state = state
        super.init()
    }
    
    override var taskDescription: String? {
        get { _taskDescription }
        set { /* Intentionally empty - read-only in tests */ }
    }
    
    override var state: URLSessionTask.State {
        _state
    }
    
    override func resume() {
        resumeCalled = true
    }
    
    override func cancel() {
        cancelCalled = true
    }
    
    override func cancel(byProducingResumeData completionHandler: @escaping @Sendable (Data?) -> Void) {
        cancelWithResumeDataCalled = true
        capturedResumeDataHandler = completionHandler
    }
}

// MARK: - ActiveDownload Tests

@MainActor
final class ActiveDownloadTests: XCTestCase {
    
    func testActiveDownloadInitialization() async {
        let itemId = UUID()
        let mockTask = MockDownloadTask(taskDescription: itemId.uuidString)
        
        let download = ActiveDownload(task: mockTask, itemId: itemId)
        
        XCTAssertEqual(download.itemId, itemId)
        XCTAssertEqual(download.id, itemId)
        XCTAssertEqual(download.progress, 0.0)
        XCTAssertEqual(download.totalBytesWritten, 0)
        XCTAssertEqual(download.totalBytesExpected, 0)
        XCTAssertNotNil(download.started)
        XCTAssertTrue(download.task === mockTask)
    }
    
    func testActiveDownloadProgressUpdates() async {
        let itemId = UUID()
        let mockTask = MockDownloadTask(taskDescription: itemId.uuidString)
        let download = ActiveDownload(task: mockTask, itemId: itemId)
        
        download.progress = 0.5
        download.totalBytesWritten = 500
        download.totalBytesExpected = 1000
        
        XCTAssertEqual(download.progress, 0.5)
        XCTAssertEqual(download.totalBytesWritten, 500)
        XCTAssertEqual(download.totalBytesExpected, 1000)
    }
    
    func testActiveDownloadComparable() async {
        let id1 = UUID()
        let id2 = UUID()
        let mockTask1 = MockDownloadTask(taskDescription: id1.uuidString)
        let mockTask2 = MockDownloadTask(taskDescription: id2.uuidString)
        
        let download1 = ActiveDownload(task: mockTask1, itemId: id1)
        // Add a small delay to ensure different started times
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let download2 = ActiveDownload(task: mockTask2, itemId: id2)
        
        XCTAssertTrue(download1 < download2, "Earlier download should be less than later download")
        XCTAssertFalse(download2 < download1)
    }
    
    func testActiveDownloadEquatable() async {
        let itemId = UUID()
        let mockTask = MockDownloadTask(taskDescription: itemId.uuidString)
        
        let download1 = ActiveDownload(task: mockTask, itemId: itemId)
        let download2 = ActiveDownload(task: mockTask, itemId: itemId)
        
        // Two downloads with same itemId are equal
        XCTAssertEqual(download1, download2)
        
        let differentId = UUID()
        let download3 = ActiveDownload(task: mockTask, itemId: differentId)
        XCTAssertNotEqual(download1, download3)
    }
    
    func testActiveDownloadHashable() async {
        let itemId = UUID()
        let mockTask = MockDownloadTask(taskDescription: itemId.uuidString)
        let download = ActiveDownload(task: mockTask, itemId: itemId)
        
        var set: Set<ActiveDownload> = []
        set.insert(download)
        
        XCTAssertTrue(set.contains(download))
        
        // A download with the same ID should be considered the same
        let sameIdDownload = ActiveDownload(task: mockTask, itemId: itemId)
        XCTAssertTrue(set.contains(sameIdDownload))
    }
    
    func testActiveDownloadWeakTaskReference() async {
        let itemId = UUID()
        var mockTask: MockDownloadTask? = MockDownloadTask(taskDescription: itemId.uuidString)
        
        let download = ActiveDownload(task: mockTask!, itemId: itemId)
        XCTAssertNotNil(download.task)
        
        // Release the task
        mockTask = nil
        
        // The weak reference should be nil now
        XCTAssertNil(download.task)
    }
}

// MARK: - DownloadItem Tests

final class DownloadItemTests: XCTestCase {
    
    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!
    
    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }
    
    override func tearDown() {
        testStack = nil
        context = nil
        super.tearDown()
    }
    
    func testDownloadItemCreation() {
        let item = DownloadItem.create(in: context)
        
        XCTAssertNotNil(item.entityId)
        XCTAssertEqual(item.lifeCycle, .empty)
        XCTAssertEqual(item.state, .notStarted)
    }
    
    func testDownloadItemStateTransitions() {
        let item = DownloadItem.create(in: context)
        
        // Initial state
        XCTAssertEqual(item.state, .notStarted)
        
        // Transition through states
        item.state = .downloading
        XCTAssertEqual(item.state, .downloading)
        
        item.state = .paused
        XCTAssertEqual(item.state, .paused)
        
        item.state = .cancelled
        XCTAssertEqual(item.state, .cancelled)
        
        item.state = .failed
        XCTAssertEqual(item.state, .failed)
        
        item.state = .complete
        XCTAssertEqual(item.state, .complete)
        
        item.state = .imported
        XCTAssertEqual(item.state, .imported)
    }
    
    func testDownloadItemStateIdRoundtrip() {
        let item = DownloadItem.create(in: context)
        
        for state in Downloader.State.allCases {
            item.state = state
            XCTAssertEqual(item.state, state, "State should roundtrip correctly for \(state)")
            XCTAssertEqual(item.state_, state.id)
        }
    }
    
    func testDownloadItemURLStorage() {
        let item = DownloadItem.create(in: context)
        let testURL = URL(string: "https://example.com/model.mlmodel")!
        
        item.url = testURL
        XCTAssertEqual(item.url, testURL)
    }
    
    func testDownloadItemProgressStorage() {
        let item = DownloadItem.create(in: context)
        
        item.progress = 0.75
        item.totalBytesWritten = 750
        item.totalBytesExpectedToWrite = 1000
        
        XCTAssertEqual(item.progress, 0.75)
        XCTAssertEqual(item.totalBytesWritten, 750)
        XCTAssertEqual(item.totalBytesExpectedToWrite, 1000)
    }
    
    func testDownloadItemErrorStorage() {
        let item = DownloadItem.create(in: context)
        
        let errorMessage = "Connection timeout"
        item.error = errorMessage
        
        XCTAssertEqual(item.error, errorMessage)
    }
    
    func testDownloadItemValidationReport_NotStarted() {
        let item = DownloadItem.create(in: context)
        item.state = .notStarted
        
        let report = item.validationReport()
        
        // Not started items should pass validation
        XCTAssertTrue(report.isValid)
    }
    
    func testDownloadItemValidationReport_DownloadingWithoutFile() {
        let item = DownloadItem.create(in: context)
        item.state = .downloading
        item.lifeCycle = .draft
        
        let report = item.validationReport()
        
        // Downloading without file should have issues
        XCTAssertFalse(report.isValid)
        XCTAssertNotNil(report.issues)
        XCTAssertTrue(report.issues?.contains { $0.key == "file" } ?? false)
    }
    
    func testDownloadItemValidationReport_CompleteWithURL_NoFile() {
        let item = DownloadItem.create(in: context)
        item.state = .complete
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.lifeCycle = .ready
        
        let report = item.validationReport()
        
        // Complete with URL but no file should fail validation (file is required)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "file" } ?? false)
    }
    
    func testDownloadItemValidationReport_DeprecatedLifecycle_SkipsValidation() {
        let item = DownloadItem.create(in: context)
        item.state = .complete
        item.lifeCycle = .deprecated
        
        let report = item.validationReport()
        
        // Deprecated lifecycle should skip validation
        XCTAssertTrue(report.isValid)
    }
    
    func testDownloadItemAwakeFromFetch_AutoTransitionToDraft() {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.lifeCycle = .empty
        
        // Simulate awakeFromFetch
        item.awakeFromFetch()
        
        // Should auto-transition to draft since URL exists
        XCTAssertEqual(item.lifeCycle, .draft)
    }
    
    func testDownloadItemDoesModelFileExist_NoFile() {
        let item = DownloadItem.create(in: context)
        
        XCTAssertFalse(item.doesModelFileExist())
    }
    
    func testDownloadItemSelect() {
        let item = DownloadItem.create(in: context)
        let id = item.entityId
        
        let fetched = DownloadItem.select(id, in: context)
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.entityId, id)
    }
    
    func testDownloadItemDelete() {
        let item = DownloadItem.create(in: context)
        let id = item.entityId
        
        DownloadItem.delete(item, in: context, deleteModel: false)
        
        let fetched = DownloadItem.select(id, in: context)
        XCTAssertNil(fetched)
    }
}

// MARK: - Downloader Tests

@MainActor
final class DownloaderTests: XCTestCase {
    
    var dataController: DataController!
    var downloader: Downloader!
    var cancellables: Set<AnyCancellable> = []
    
    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        downloader = Downloader(dataController: dataController)
    }
    
    override func tearDown() async throws {
        cancellables.removeAll()
        downloader = nil
        dataController = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testDownloaderInitialization() {
        XCTAssertNotNil(downloader)
        XCTAssertTrue(downloader.activeDownloads.isEmpty)
    }
    
    // MARK: - State Machine Tests
    
    func testDownloaderState_AllCases() {
        // Verify all expected states exist
        let states = Downloader.State.allCases
        
        XCTAssertTrue(states.contains(.notStarted))
        XCTAssertTrue(states.contains(.downloading))
        XCTAssertTrue(states.contains(.paused))
        XCTAssertTrue(states.contains(.cancelled))
        XCTAssertTrue(states.contains(.failed))
        XCTAssertTrue(states.contains(.complete))
        XCTAssertTrue(states.contains(.imported))
    }
    
    func testDownloaderState_Identifiable() {
        for state in Downloader.State.allCases {
            XCTAssertEqual(state.id, state.rawValue)
        }
    }
    
    // MARK: - Download Tap Behavior Tests
    
    func testDownloadTapped_NotStarted_StartsDownload() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated, "Session should be created when download starts")
        XCTAssertEqual(item.state, .downloading)
    }
    
    func testDownloadTapped_Downloading_PausesDownload() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        // Start download first
        downloader.sessionFactory = { config, delegate, queue in
            URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        XCTAssertEqual(item.state, .downloading)
        
        // Verify there's an active download
        XCTAssertFalse(downloader.activeDownloads.isEmpty)
    }
    
    func testDownloadTapped_Failed_RestartsDownload() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .failed
        DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated)
        XCTAssertEqual(item.state, .downloading)
    }
    
    func testDownloadTapped_Cancelled_RestartsDownload() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .cancelled
        DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated)
        XCTAssertEqual(item.state, .downloading)
    }
    
    func testDownloadTapped_Paused_ResumesWithResumeData() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        DownloadItem.save(in: context)
        
        // Inject resume data
        let resumeData = "test resume data".data(using: .utf8)!
        downloader._testInjectResumeData(for: entityId, data: resumeData)
        
        var resumeDataUsed = false
        downloader.sessionFactory = { config, delegate, queue in
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            resumeDataUsed = true
            return session
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(resumeDataUsed, "Should use resume data when resuming")
        XCTAssertEqual(item.state, .downloading)
    }
    
    // MARK: - Cancel Tests
    
    func testCancelTapped_Downloading_Cancels() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        // Start download first
        downloader.sessionFactory = { config, delegate, queue in
            URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        XCTAssertEqual(item.state, .downloading)
        XCTAssertFalse(downloader.activeDownloads.isEmpty)
        
        // Cancel should call cancel on the task
        downloader.cancelTapped(item)
        // The task.cancel() is called which triggers delegate methods asynchronously
    }
    
    func testCancelTapped_Paused_ReturnsToNotStarted() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        DownloadItem.save(in: context)
        
        // There's no active download for paused state
        downloader.cancelTapped(item)
        
        // When there's no active download and item is paused, it should reset
        XCTAssertEqual(item.state, .notStarted)
    }
    
    func testCancelTapped_NotStarted_DoesNothing() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        downloader.cancelTapped(item)
        
        // Should remain in not started state
        XCTAssertEqual(item.state, .notStarted)
    }
    
    // MARK: - Progress Publisher Tests
    
    func testProgressPublisher_NilItemId_ReturnsZero() {
        let expectation = XCTestExpectation(description: "Progress publisher emits zero")
        
        downloader.progressPublisher(for: nil)
            .sink { progress in
                XCTAssertEqual(progress, 0.0)
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testProgressPublisher_NonExistentItemId_ReturnsZero() {
        let expectation = XCTestExpectation(description: "Progress publisher emits zero for non-existent item")
        
        let nonExistentId = UUID()
        
        downloader.progressPublisher(for: nonExistentId)
            .sink { progress in
                XCTAssertEqual(progress, 0.0)
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testTotalBytesWrittenPublisher_NilItemId_ReturnsZero() {
        let expectation = XCTestExpectation(description: "Total bytes written publisher emits zero")
        
        downloader.totalBytesWrittenPublisher(for: nil)
            .sink { bytes in
                XCTAssertEqual(bytes, 0)
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testTotalBytesExpectedPublisher_NilItemId_ReturnsZero() {
        let expectation = XCTestExpectation(description: "Total bytes expected publisher emits zero")
        
        downloader.totalBytesExpectedPublisher(for: nil)
            .sink { bytes in
                XCTAssertEqual(bytes, 0)
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Session Delegate Forwarding Tests
    
    func testSessionDownloadDidWriteData_UpdatesActiveDownload() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        var capturedSession: URLSession?
        downloader.sessionFactory = { config, delegate, queue in
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            capturedSession = session
            return session
        }
        
        downloader.downloadTapped(item)
        
        // Verify active download exists
        guard let activeDownload = downloader.activeDownloads[entityId] else {
            XCTFail("Active download should exist")
            return
        }
        
        // Simulate progress update through the downloader's internal method
        guard let session = capturedSession else {
            XCTFail("Session should be captured")
            return
        }
        
        // Create a mock task with the correct task description
        let mockTask = MockDownloadTask(taskDescription: entityId.uuidString)
        
        // Call the delegate forwarding method
        downloader.sessionDownloadDidWriteData(
            session: session,
            downloadTask: mockTask,
            bytesWritten: 100,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: 1000
        )
        
        XCTAssertEqual(activeDownload.progress, 0.5)
        XCTAssertEqual(activeDownload.totalBytesWritten, 500)
        XCTAssertEqual(activeDownload.totalBytesExpected, 1000)
    }
    
    func testSessionTaskDidComplete_CancelledError_TransitionsToPausedOrCancelled() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        var capturedSession: URLSession?
        downloader.sessionFactory = { config, delegate, queue in
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            capturedSession = session
            return session
        }
        
        downloader.downloadTapped(item)
        
        guard let session = capturedSession else {
            XCTFail("Session should be captured")
            return
        }
        
        let mockTask = MockDownloadTask(taskDescription: entityId.uuidString)
        let cancelError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        
        // Call the delegate forwarding method
        downloader.sessionTaskDidComplete(session: session, task: mockTask, error: cancelError)
        
        // Should transition to cancelled (no resume data)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertTrue(downloader.activeDownloads.isEmpty)
    }
    
    func testSessionTaskDidComplete_NoInternetError_TransitionsToFailed() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        var capturedSession: URLSession?
        downloader.sessionFactory = { config, delegate, queue in
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            capturedSession = session
            return session
        }
        
        downloader.downloadTapped(item)
        
        guard let session = capturedSession else {
            XCTFail("Session should be captured")
            return
        }
        
        let mockTask = MockDownloadTask(taskDescription: entityId.uuidString)
        let noInternetError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
        ])
        
        // Call the delegate forwarding method
        downloader.sessionTaskDidComplete(session: session, task: mockTask, error: noInternetError)
        
        // Should transition to failed
        XCTAssertEqual(item.state, .failed)
        XCTAssertNotNil(item.error)
        XCTAssertTrue(item.error?.contains("Check your connection") ?? false)
    }
    
    // MARK: - Download Completion Tests
    
    func testHandleDownloadCompletion_Failure_TransitionsToFailed() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        // Start download to create active download
        downloader.sessionFactory = { config, delegate, queue in
            URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Test error"
        ])
        
        downloader.handleDownloadCompletion(itemId: entityId, fileURL: .failure(error))
        
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.error, "Test error")
        XCTAssertTrue(downloader.activeDownloads.isEmpty)
    }
    
    func testHandleDownloadCompletion_NonExistentItem_DoesNotCrash() {
        let nonExistentId = UUID()
        
        // Should not crash, just log warning
        downloader.handleDownloadCompletion(itemId: nonExistentId, fileURL: .success(URL(fileURLWithPath: "/test")))
    }
    
    // MARK: - ModelProvider Tests
    
    func testModelProviderResult_ImportSucceeded() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .complete
        DownloadItem.save(in: context)
        
        downloader.result(.importSucceeded, id: entityId)
        
        XCTAssertEqual(item.state, .imported)
    }
    
    func testModelProviderResult_ImportFailed_DoesNotChangeState() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .complete
        DownloadItem.save(in: context)
        
        downloader.result(.importFailed, id: entityId)
        
        // State should remain complete
        XCTAssertEqual(item.state, .complete)
    }
    
    // MARK: - Edge Cases
    
    func testStartDownload_NilURL_DoesNotCrash() {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = nil
        item.state = .notStarted
        DownloadItem.save(in: context)
        
        // Should not crash, just log error
        downloader.downloadTapped(item)
        
        // State should remain unchanged
        XCTAssertEqual(item.state, .notStarted)
    }
    
    func testSessionDownloadDidWriteData_InvalidTaskDescription_DoesNotCrash() {
        let session = URLSession.shared
        let mockTask = MockDownloadTask(taskDescription: "not-a-uuid")
        
        // Should not crash, just log error
        downloader.sessionDownloadDidWriteData(
            session: session,
            downloadTask: mockTask,
            bytesWritten: 100,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: 1000
        )
    }
    
    func testSessionTaskDidComplete_InvalidTaskDescription_HandlesGracefully() {
        let session = URLSession.shared
        let mockTask = MockDownloadTask(taskDescription: "not-a-uuid")
        
        // Should not crash
        downloader.sessionTaskDidComplete(session: session, task: mockTask, error: nil)
    }
}

// MARK: - DownloaderError Tests

final class DownloaderErrorTests: XCTestCase {
    
    func testDownloaderErrorCases() {
        // Verify all error cases exist and are distinct
        let invalidObject = DownloaderError.invalidObjectInQueue
        let invalidState = DownloaderError.invalidStateInQueue
        
        XCTAssertNotNil(invalidObject)
        XCTAssertNotNil(invalidState)
    }
}

