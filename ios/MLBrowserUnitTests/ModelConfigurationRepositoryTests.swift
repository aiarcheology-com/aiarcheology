//
//  ModelConfigurationRepositoryTests.swift
//  AI ArcheologyTests
//
//  AIA-0388: the config concern, unit-tested against Core Data ALONE — no drivers, no FileManager.
//

import XCTest
@testable import ML_Browser

@MainActor
final class ModelConfigurationRepositoryTests: XCTestCase {

	private var dataController: DataController!
	private var repository: ModelConfigurationRepository!

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		repository = ModelConfigurationRepository(dataController: dataController)
	}

	override func tearDown() async throws {
		repository = nil
		dataController = nil
		try await super.tearDown()
	}

	func testCreate_insertsSelectableRow() {
		let config = repository.create()
		XCTAssertNotNil(repository.select(config.entityId))
	}

	func testSelectAll_returnsEveryCreatedRow() {
		_ = repository.create()
		_ = repository.create()
		XCTAssertEqual(repository.selectAll().count, 2)
	}

	func testSelect_missingId_returnsNil() {
		XCTAssertNil(repository.select(UUID()))
	}

	func testUpdate_appliesTheClosure() throws {
		let config = repository.create()
		try repository.save()

		try repository.update(config.entityId) { $0.modelType = .classificator }

		XCTAssertEqual(repository.select(config.entityId)?.modelType, .classificator)
	}

	func testDelete_removesRowAndClearsPresentationDefaults() throws {
		let config = repository.create()
		let id = config.entityId
		// Per-model preferences persist outside Core Data.
		config.flashOnFindingEnabled = false
		config.detectionConfidenceThreshold = 0.4
		try repository.save()
		let flashKey = "deepConfiguration.flash.enabled.\(id.uuidString)"
		let confidenceKey = "deepConfiguration.detection.confidence.\(id.uuidString)"
		XCTAssertNotNil(UserDefaults.standard.object(forKey: flashKey))
		XCTAssertNotNil(UserDefaults.standard.object(forKey: confidenceKey))

		repository.delete(id)

		XCTAssertNil(repository.select(id), "row removed")
		XCTAssertNil(UserDefaults.standard.object(forKey: flashKey), "flash default cleared with the row")
		XCTAssertNil(UserDefaults.standard.object(forKey: confidenceKey), "confidence default cleared with the row")
	}

	func testReset_removesEveryRowAndClearsPresentationDefaults() async throws {
		// Batch delete is unsupported by an in-memory store, so exercise the real reset path against
		// a unique SQLite store (the same persistence mechanism the app uses).
		let storeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ModelConfigurationRepositoryReset-\(UUID().uuidString).sqlite")
		defer {
			for suffix in ["", "-wal", "-shm"] {
				try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
			}
		}
		let diskController = DataController(storeURL: storeURL)
		await diskController.awaitStoreReady()
		let diskRepository = ModelConfigurationRepository(dataController: diskController)
		let first = diskRepository.create()
		let second = diskRepository.create()
		let ids = [first.entityId, second.entityId]
		for configuration in [first, second] {
			configuration.flashOnFindingEnabled = false
			configuration.detectionConfidenceThreshold = 0.4
		}
		try diskRepository.save()

		try await diskRepository.reset()

		XCTAssertTrue(diskRepository.selectAll().isEmpty)
		for id in ids {
			XCTAssertNil(UserDefaults.standard.object(forKey: "deepConfiguration.flash.enabled.\(id.uuidString)"))
			XCTAssertNil(UserDefaults.standard.object(forKey: "deepConfiguration.detection.confidence.\(id.uuidString)"))
		}
	}
}
