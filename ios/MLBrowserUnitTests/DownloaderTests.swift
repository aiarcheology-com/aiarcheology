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

// MARK: - Mock DownloadTask (Protocol-based)

/// A protocol-conforming mock for testing download tasks.
/// Uses DownloadTaskProtocol instead of subclassing URLSessionDownloadTask,
/// avoiding the deprecated URLSessionDownloadTask.init() warning.
final class MockDownloadTask: DownloadTaskProtocol, @unchecked Sendable {
    var resumeCalled = false
    var cancelCalled = false
    var cancelWithResumeDataCalled = false
    var capturedResumeDataHandler: (@Sendable (Data?) -> Void)?
    
    var taskDescription: String?
    private(set) var state: URLSessionTask.State
    
    init(taskDescription: String? = nil, state: URLSessionTask.State = .suspended) {
        self.taskDescription = taskDescription
        self.state = state
    }
    
    func resume() {
        resumeCalled = true
    }
    
    func cancel() {
        cancelCalled = true
    }
    
    func cancel(byProducingResumeData completionHandler: @escaping @Sendable (Data?) -> Void) {
        cancelWithResumeDataCalled = true
        capturedResumeDataHandler = completionHandler
    }
}

private final class PackageDownloadURLProtocol: URLProtocol, @unchecked Sendable {
	nonisolated(unsafe) static var responseHandler: ((URL) -> Data)?

	// swiftlint:disable:next static_over_final_class
	override class func canInit(with request: URLRequest) -> Bool {
		request.url?.host == "catalog.test"
	}

	// swiftlint:disable:next static_over_final_class
	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		guard let url = request.url, let data = Self.responseHandler?(url) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		guard let response = HTTPURLResponse(
			url: url,
			statusCode: 200,
			httpVersion: "HTTP/1.1",
			headerFields: ["Content-Length": String(data.count)]
		) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() { }
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
    
    func testActiveDownloadRetainsTask() async {
        let itemId = UUID()
        var mockTask: MockDownloadTask? = MockDownloadTask(taskDescription: itemId.uuidString)

        let download = ActiveDownload(task: mockTask!, itemId: itemId)

        // Release the external reference — ActiveDownload must keep the task alive
        // so pause/cancel keep working for the lifetime of the download.
        weak var weakTask: MockDownloadTask?
        weakTask = mockTask
        mockTask = nil

        XCTAssertNotNil(weakTask, "ActiveDownload should retain its task")
        XCTAssertTrue(download.task === weakTask)
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

        item.state = .importFailed
        XCTAssertEqual(item.state, .importFailed)
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
    
    func testDownloadItemResumeDataStorage() throws {
        let item = DownloadItem.create(in: context)
        
        // Initially nil
        XCTAssertNil(item.resumeData)
        
        // Set resume data
        let testData = Data("test resume data for persistence".utf8)
        item.resumeData = testData
        try DownloadItem.save(in: context)
        
        // Verify stored
        XCTAssertEqual(item.resumeData, testData)
        
        // Clear resume data
        item.resumeData = nil
        try DownloadItem.save(in: context)
        
        XCTAssertNil(item.resumeData)
    }
    
    func testDownloadItemValidationReport_NotStarted() {
        let item = DownloadItem.create(in: context)
        item.state = .notStarted
        
        let report = item.validationReport()
        
        // Not started items should pass validation
        XCTAssertTrue(report.isValid)
    }
    
    func testDownloadItemValidationReport_DownloadingWithoutFile_IsValid() {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .downloading
        item.lifeCycle = .ready

        let report = item.validationReport()

        // The file does not exist until the download finishes; mid-download
        // states must validate (and therefore save) without it.
        XCTAssertTrue(report.isValid)
    }

    func testDownloadItemValidationReport_DownloadingWithoutURL_IsNotValid() {
        let item = DownloadItem.create(in: context)
        item.state = .downloading
        item.lifeCycle = .ready

        let report = item.validationReport()

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "url" } ?? false)
    }

    func testDownloadItemValidationReport_ImportFailedWithoutFile_IsNotValid() {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .importFailed
        item.lifeCycle = .ready

        let report = item.validationReport()

        // .importFailed implies a finished download — the file must exist for retry.
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues?.contains { $0.key == "file" } ?? false)
    }

    func testSave_ReadyLifeCycle_Downloading_DoesNotThrow() throws {
        // Regression: starting a download promotes lifeCycle to .ready and state to
        // .downloading while file_ is still nil; saves during the download (state
        // transition, resume-data persistence) must not throw.
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.lifeCycle = .ready
        item.state = .downloading
        item.file_ = nil

        XCTAssertNoThrow(try DownloadItem.save(in: context))
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
    
    // MARK: - Lifecycle-Aware Validation Tests
    
    func testValidateForInsert_EmptyLifeCycle_DoesNotThrowForInvalidData() throws {
        let item = DownloadItem(context: context)
        item.entityId = UUID()
        item.lifeCycle = .empty
        // Missing required fields (no URL, no file)
        item.url = nil
        item.file_ = nil
        
        // Should not throw during insert validation when lifeCycle is .empty
        XCTAssertNoThrow(try item.validateForInsert())
    }
    
    func testValidateForInsert_DraftLifeCycle_DoesNotThrowForInvalidData() throws {
        let item = DownloadItem(context: context)
        item.entityId = UUID()
        item.lifeCycle = .draft
        // Missing required fields (no file, even though state is complete)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .complete
        item.file_ = nil
        
        // Should not throw during insert validation when lifeCycle is .draft
        XCTAssertNoThrow(try item.validateForInsert())
    }
    
    func testValidateForInsert_ReadyLifeCycle_ThrowsForInvalidData() throws {
        let item = DownloadItem(context: context)
        item.entityId = UUID()
        item.lifeCycle = .ready
        item.state = .complete
        // Missing required file field
        item.file_ = nil
        
        // Should throw during insert validation when lifeCycle is .ready
        XCTAssertThrowsError(try item.validateForInsert())
    }
    
    func testValidateForInsert_ReadyLifeCycle_DoesNotThrowForValidData() throws {
        let item = DownloadItem(context: context)
        item.entityId = UUID()
        item.lifeCycle = .ready
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.file_ = URL(fileURLWithPath: "/tmp/test.mlmodel")
        item.state = .complete
        
        // Should not throw during insert validation when data is valid
        XCTAssertNoThrow(try item.validateForInsert())
    }
    
    func testValidateForUpdate_EmptyLifeCycle_DoesNotThrowForInvalidData() throws {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        try context.save()
        
        // Make invalid and change to empty lifecycle
        item.file_ = nil
        item.lifeCycle = .empty
        
        // Should not throw during update validation when lifeCycle is .empty
        XCTAssertNoThrow(try item.validateForUpdate())
    }
    
    func testValidateForUpdate_DraftLifeCycle_DoesNotThrowForInvalidData() throws {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.lifeCycle = .draft
        try context.save()
        
        // Make invalid while in draft lifecycle
        item.file_ = nil
        item.state = .complete
        
        // Should not throw during update validation when lifeCycle is .draft
        XCTAssertNoThrow(try item.validateForUpdate())
    }
    
    func testValidateForUpdate_ReadyLifeCycle_ThrowsForInvalidData() throws {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.file_ = URL(fileURLWithPath: "/tmp/test.mlmodel")
        item.lifeCycle = .ready
        item.state = .complete
        try context.save()

        // Make invalid while in ready state
        item.file_ = nil

        // Should throw during update validation when lifeCycle is .ready
        XCTAssertThrowsError(try item.validateForUpdate())
    }

    func testValidateForUpdate_ReadyLifeCycle_DoesNotThrowForValidData() throws {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.file_ = URL(fileURLWithPath: "/tmp/test.mlmodel")
        item.lifeCycle = .ready
        try context.save()
        
        // Update with valid data
        item.progress = 1.0
        
        // Should not throw during update validation when data is valid
        XCTAssertNoThrow(try item.validateForUpdate())
    }
    
    func testValidateForUpdate_TransitioningToReady_ThrowsForInvalidData() throws {
        let item = DownloadItem(context: context)
        item.entityId = UUID()
        item.lifeCycle = .draft
        item.state = .complete
        // Missing required file
        item.file_ = nil
        try context.save()
        
        // Transition to ready with invalid data
        item.lifeCycle = .ready
        
        // Should throw during update validation when transitioning to .ready with invalid data
        XCTAssertThrowsError(try item.validateForUpdate())
    }

    func testValidateForUpdate_TransitioningToReady_DoesNotThrowForValidData() throws {
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.file_ = URL(fileURLWithPath: "/tmp/test.mlmodel")
        item.lifeCycle = .draft
        try context.save()
        
        // Transition to ready with valid data
        item.lifeCycle = .ready
        
        // Should not throw during update validation when transitioning to .ready with valid data
        XCTAssertNoThrow(try item.validateForUpdate())
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
		PackageDownloadURLProtocol.responseHandler = nil
        downloader = nil
        dataController = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testDownloaderInitialization() {
        XCTAssertNotNil(downloader)
        XCTAssertTrue(downloader.activeDownloads.isEmpty)
		XCTAssertTrue(downloader.activePackageDownloads.isEmpty)
    }

	func testMakePackageDownloadItem_persistsJobManifestForRetry() throws {
		let context = dataController.container.viewContext
		let files = catalogPackageFiles()

		let item = try downloader.makePackageDownloadItem(files: files, in: context)
		let restoredDownloader = Downloader(dataController: dataController)

		XCTAssertEqual(item.url, files[0].resolveURL)
		XCTAssertEqual(item.lifeCycle, .draft)
		XCTAssertTrue(downloader.isPackageDownload(item))
		XCTAssertEqual(restoredDownloader.packageFileCount(for: item), files.count)
	}

	func testCatalogDownloadItem_reusesTheExistingArtifactJob() throws {
		let file = CatalogFile(
			relativePath: "Example.mlmodel",
			resolveURL: URL(string: "https://catalog.test/Example.mlmodel") ?? URL(fileURLWithPath: "/"),
			sizeBytes: 64
		)
		let context = dataController.container.viewContext

		let firstItem = try downloader.catalogDownloadItem(files: [file], in: context)
		firstItem.state = .downloading
		let reopenedItem = try downloader.catalogDownloadItem(files: [file], in: context)

		XCTAssertTrue(firstItem === reopenedItem)
		XCTAssertEqual(firstItem.entityId, reopenedItem.entityId)
		XCTAssertEqual(reopenedItem.state, .downloading)
		XCTAssertEqual(try context.count(for: DownloadItem.fetchRequest()), 1)
	}

	func testCancelPackageDownload_keepsManifestForRestart() throws {
		let item = try downloader.makePackageDownloadItem(
			files: catalogPackageFiles(),
			in: dataController.container.viewContext
		)

		downloader.downloadTapped(item)
		XCTAssertEqual(item.state, .downloading)
		XCTAssertNotNil(downloader.activePackageDownloads[item.entityId])

		downloader.cancelTapped(item)

		XCTAssertEqual(item.state, .cancelled)
		XCTAssertTrue(downloader.activePackageDownloads.isEmpty)
		XCTAssertTrue(downloader.isPackageDownload(item))
	}

	func testPackageDownload_usesSharedDownloaderAndMovesWholePackage() async throws {
		PackageDownloadURLProtocol.responseHandler = { url in
			switch url.lastPathComponent {
			case "Manifest.json": return Data("manifest".utf8)
			case "model.mlmodel": return Data("model".utf8)
			case "weight.bin": return Data("weights".utf8)
			default: return Data()
			}
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [PackageDownloadURLProtocol.self]
		let packageDownloader = CatalogPackageDownloader(session: URLSession(configuration: configuration))
		downloader = Downloader(dataController: dataController, packageDownloader: packageDownloader)
		let item = try downloader.makePackageDownloadItem(
			files: catalogPackageFiles(),
			in: dataController.container.viewContext
		)
		defer {
			if let directory = FileManager.deepConfigurationDirectory(id: item.entityId) {
				try? FileManager.default.removeItem(at: directory)
			}
		}

		downloader.downloadTapped(item)
		for _ in 0..<50 where item.state != .complete {
			try await Task.sleep(for: .milliseconds(20))
		}

		let packageURL = try XCTUnwrap(item.file)
		XCTAssertEqual(item.state, .complete)
		XCTAssertEqual(try Data(contentsOf: packageURL.appendingPathComponent("Manifest.json")), Data("manifest".utf8))
		XCTAssertEqual(
			try Data(contentsOf: packageURL.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")),
			Data("weights".utf8)
		)
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
        XCTAssertTrue(states.contains(.importFailed))
    }
    
    func testDownloaderState_Identifiable() {
        for state in Downloader.State.allCases {
            XCTAssertEqual(state.id, state.rawValue)
        }
    }
    
    // MARK: - Download Tap Behavior Tests
    
    func testDownloadTapped_NotStarted_StartsDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated, "Session should be created when download starts")
        XCTAssertEqual(item.state, .downloading)
    }
    
    func testDownloadTapped_Downloading_PausesDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
        // Start download first
        downloader.sessionFactory = { config, delegate, queue in
            URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        XCTAssertEqual(item.state, .downloading)
        
        // Verify there's an active download
        XCTAssertFalse(downloader.activeDownloads.isEmpty)
    }
    
    func testDownloadTapped_Failed_RestartsDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .failed
        try DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated)
        XCTAssertEqual(item.state, .downloading)
    }
    
    func testDownloadTapped_Cancelled_RestartsDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .cancelled
        try DownloadItem.save(in: context)

        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }

        downloader.downloadTapped(item)

        XCTAssertTrue(sessionCreated)
        XCTAssertEqual(item.state, .downloading)
    }

    func testDownloadTapped_ImportFailed_RestartsDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .importFailed
        try DownloadItem.save(in: context)

        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }

        downloader.downloadTapped(item)

        XCTAssertTrue(sessionCreated)
        XCTAssertEqual(item.state, .downloading)
    }

    func testDownloadTapped_Paused_ResumesWithResumeData() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        try DownloadItem.save(in: context)
        
        // Inject resume data
        let resumeData = Data("test resume data".utf8)
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
    
    func testCancelTapped_Downloading_Cancels() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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
    
    func testCancelTapped_Paused_TransitionsToCancelled() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        item.progress = 0.5
        item.resumeData = Data("test".utf8)
        try DownloadItem.save(in: context)
        
        // There's no active download for paused state
        downloader.cancelTapped(item)
        
        // When cancelling from paused state, should reset progress and transition to cancelled
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.progress, 0.0, "Progress should be reset when cancelling")
        XCTAssertNil(item.resumeData, "Resume data should be cleared when cancelling")
    }
    
    func testCancelTapped_NotStarted_DoesNothing() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
        downloader.cancelTapped(item)
        
        // Should remain in not started state
        XCTAssertEqual(item.state, .notStarted)
    }
    
    // MARK: - Resume Data Persistence Tests
    
    func testResumeData_LoadedFromCoreData_WhenResuming() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        item.progress = 0.5
        item.totalBytesWritten = 500
        item.totalBytesExpectedToWrite = 1000
        
        // Simulate persisted resume data (as if app was killed while paused)
        let testResumeData = Data("resume data from CoreData".utf8)
        item.resumeData = testResumeData
        try DownloadItem.save(in: context)
        
        var sessionCreated = false
        downloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        // Resume download - should use resume data from CoreData
        downloader.downloadTapped(item)
        
        XCTAssertTrue(sessionCreated, "Session should be created when resuming")
        XCTAssertEqual(item.state, .downloading)
        XCTAssertNil(item.resumeData, "Resume data should be cleared after using")
    }
    
    func testResumeData_ClearedFromCoreData_WhenCancelling() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        item.progress = 0.75
        item.resumeData = Data("test resume data".utf8)
        try DownloadItem.save(in: context)
        
        XCTAssertNotNil(item.resumeData, "Resume data should exist before cancelling")
        
        downloader.cancelTapped(item)
        
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertNil(item.resumeData, "Resume data should be cleared when cancelling")
        XCTAssertEqual(item.progress, 0.0, "Progress should be reset when cancelling")
    }
    
    func testResumeData_SurvivesDownloaderReinitialization() throws {
        // This tests that resume data persists across "app restarts" (simulated by creating new Downloader)
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        item.progress = 0.6
        item.resumeData = Data("persisted resume data".utf8)
        try DownloadItem.save(in: context)
        
        // Create a new Downloader (simulates app restart)
        let newDownloader = Downloader(dataController: dataController)
        
        var sessionCreated = false
        newDownloader.sessionFactory = { config, delegate, queue in
            sessionCreated = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        }
        
        // Re-fetch item (simulates fresh fetch after restart)
        guard let refetchedItem = DownloadItem.select(entityId, in: context) else {
            XCTFail("Item should exist in CoreData")
            return
        }
        
        // Verify resume data survived
        XCTAssertNotNil(refetchedItem.resumeData, "Resume data should persist in CoreData")
        XCTAssertEqual(refetchedItem.state, .paused)
        
        // Resume download
        newDownloader.downloadTapped(refetchedItem)
        
        XCTAssertTrue(sessionCreated, "Session should be created with persisted resume data")
        XCTAssertEqual(refetchedItem.state, .downloading)
    }
    
    func testTestHelper_InjectResumeData_SavesToCoreData() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .paused
        try DownloadItem.save(in: context)
        
        XCTAssertNil(item.resumeData, "Resume data should be nil initially")
        
        // Use test helper to inject resume data
        let testData = Data("injected via test helper".utf8)
        downloader._testInjectResumeData(for: entityId, data: testData)
        
        // Re-fetch to verify persistence
        guard let refetchedItem = DownloadItem.select(entityId, in: context) else {
            XCTFail("Item should exist")
            return
        }
        
        XCTAssertEqual(refetchedItem.resumeData, testData, "Test helper should save resume data to CoreData")
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
    
    func testSessionDownloadDidWriteData_UpdatesActiveDownload() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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
    
    func testSessionTaskDidComplete_CancelledError_TransitionsToPausedOrCancelled() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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
    
    func testSessionTaskDidComplete_NoInternetError_TransitionsToFailed() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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
    
    func testHandleDownloadCompletion_Failure_TransitionsToFailed() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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
    
    func testModelProviderResult_ImportSucceeded() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .complete
        try DownloadItem.save(in: context)
        
        downloader.result(.importSucceeded, id: entityId)
        
        XCTAssertEqual(item.state, .imported)
    }
    
    func testModelProviderResult_ImportFailed_TransitionsToImportFailed() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        let entityId = item.entityId
        item.url = URL(string: "https://example.com/model.mlmodel")!
        item.state = .complete
        try DownloadItem.save(in: context)

        downloader.result(.importFailed, id: entityId)

        XCTAssertEqual(item.state, .importFailed)
    }
    
    // MARK: - Edge Cases
    
    func testStartDownload_NilURL_DoesNotCrash() throws {
        let context = dataController.container.viewContext
        let item = DownloadItem.create(in: context)
        item.url = nil
        item.state = .notStarted
        try DownloadItem.save(in: context)
        
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

    // MARK: - Background URLSession plumbing

    func testBackgroundSessionIdentifier_HasExpectedValue() {
        XCTAssertEqual(Downloader.backgroundSessionIdentifier, "com.aiarcheology.mlbrowser.download")
    }

    func testBackgroundSessionDidFinishEvents_CallsCompletionHandlerAndClearsIt() {
        let expectation = XCTestExpectation(description: "Background completion handler called")

        downloader.backgroundSessionCompletionHandler = {
            expectation.fulfill()
        }

        downloader.backgroundSessionDidFinishEvents()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(downloader.backgroundSessionCompletionHandler, "Completion handler should be cleared after being called")
    }

    func testBackgroundSessionDidFinishEvents_WhenNoHandler_DoesNothing() {
        downloader.backgroundSessionCompletionHandler = nil
        downloader.backgroundSessionDidFinishEvents() // should not crash
    }

    func testReconnectBackgroundSession_IsNoOpUnderTests() {
        // In unit tests, Downloader.shouldUseBackgroundSession is expected to be false
        // (gated by AppEnvironment.isRunningUnderAnyTests).
        XCTAssertFalse(Downloader.shouldUseBackgroundSession)

        // Should return early and not crash / mutate downloads.
        let before = downloader.activeDownloads
        downloader.reconnectBackgroundSession()
        XCTAssertEqual(before.keys.sorted(), downloader.activeDownloads.keys.sorted())
    }
}

private extension DownloaderTests {
	func catalogPackageFiles() -> [CatalogFile] {
		[
			CatalogFile(
				relativePath: "Example.mlpackage/Manifest.json",
				resolveURL: URL(string: "https://catalog.test/Manifest.json") ?? URL(fileURLWithPath: "/"),
				sizeBytes: 16
			),
			CatalogFile(
				relativePath: "Example.mlpackage/Data/com.apple.CoreML/model.mlmodel",
				resolveURL: URL(string: "https://catalog.test/model.mlmodel") ?? URL(fileURLWithPath: "/"),
				sizeBytes: 32
			),
			CatalogFile(
				relativePath: "Example.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
				resolveURL: URL(string: "https://catalog.test/weight.bin") ?? URL(fileURLWithPath: "/"),
				sizeBytes: 64
			)
		]
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
