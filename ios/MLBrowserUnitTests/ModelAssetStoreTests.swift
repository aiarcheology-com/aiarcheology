//
//  ModelAssetStoreTests.swift
//  AI ArcheologyTests
//
//  AIA-0388: the asset concern, unit-tested against FileManager + DownloadItem ALONE — no config
//  repository CRUD, no drivers. Guards the AIA-0388 BLOCKER: a config linked to a DownloadItem
//  (any state) must KEEP its model file.
//

import XCTest
@testable import ML_Browser

@MainActor
final class ModelAssetStoreTests: XCTestCase {

	private var dataController: DataController!
	private var assetStore: ModelAssetStore!
	private var createdDirs: [URL] = []

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		assetStore = ModelAssetStore(dataController: dataController)
	}

	override func tearDown() async throws {
		for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
		createdDirs = []
		assetStore = nil
		dataController = nil
		try await super.tearDown()
	}

	/// Seeds a real model file on disk for `id`; the directory is removed in tearDown.
	private func seedModelFile(for id: UUID) throws -> URL {
		let dir = try XCTUnwrap(FileManager.deepConfigurationDirectory(id: id))
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		createdDirs.append(dir)
		let file = dir.appendingPathComponent("model.bin")
		FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))
		return file
	}

	private func seedDownloadItem(id: UUID, state: Downloader.State) throws {
		let item = DownloadItem.create(in: dataController.container.viewContext)
		item.entityId = id
		item.state = state
		try DownloadItem.save(in: dataController.container.viewContext)
	}

	/// BLOCKER regression (AIA-0388): a config referenced by a non-`.imported` DownloadItem keeps
	/// its file and the item's state is untouched.
	func testCleanup_linkedNonImportedItem_fileSurvivesAndStateUnchanged() async throws {
		let id = UUID()
		try seedDownloadItem(id: id, state: .complete)
		let file = try seedModelFile(for: id)

		try await assetStore.cleanup(entityId: id, demo: false)

		XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "linked item → file must survive")
		XCTAssertEqual(DownloadItem.select(id, in: dataController.container.viewContext)?.state, .complete)
	}

	/// A `.imported` linked item is transitioned back to `.complete`; the file still survives.
	func testCleanup_importedItem_transitionsToCompleteAndKeepsFile() async throws {
		let id = UUID()
		try seedDownloadItem(id: id, state: .imported)
		let file = try seedModelFile(for: id)

		try await assetStore.cleanup(entityId: id, demo: false)

		XCTAssertEqual(DownloadItem.select(id, in: dataController.container.viewContext)?.state, .complete)
		XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
	}

	/// A demo config skips all asset work — a linked `.imported` item is NOT transitioned.
	func testCleanup_demo_skipsAllAssetWork() async throws {
		let id = UUID()
		try seedDownloadItem(id: id, state: .imported)

		try await assetStore.cleanup(entityId: id, demo: true)

		XCTAssertEqual(DownloadItem.select(id, in: dataController.container.viewContext)?.state, .imported,
					   "demo skip → item untouched")
	}
}
