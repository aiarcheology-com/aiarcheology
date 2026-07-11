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

	func testDelete_removesRowAndClearsFlashDefaults() throws {
		let config = repository.create()
		let id = config.entityId
		// Writing a per-model flash pref persists a UserDefaults key (AIA-0374).
		config.flashOnFindingEnabled = false
		try repository.save()
		let flashKey = "deepConfiguration.flash.enabled.\(id.uuidString)"
		XCTAssertNotNil(UserDefaults.standard.object(forKey: flashKey))

		repository.delete(id)

		XCTAssertNil(repository.select(id), "row removed")
		XCTAssertNil(UserDefaults.standard.object(forKey: flashKey), "flash default cleared with the row")
	}
}
