//
//  StagedImageCaptureTests.swift
//  MLBrowserUnitTests
//
//  AIA-0975.
//

import CoreData
import UIKit
import Vision
import XCTest
@testable import ML_Browser

/// The headless find → save loop on a staged image: real detection orchestration over stub drivers,
/// a real image file, and the real repository on in-memory Core Data.
@MainActor
final class StagedImageCaptureTests: XCTestCase {

	private var dataController: DataController!
	private var deep: DeepState!
	private var repository: FindingRepository!
	private var stagedDirectory: URL!

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		deep = DeepState(dataController: dataController)
		repository = FindingRepository(dataController: dataController)
		stagedDirectory = FileManager.default.temporaryDirectory
			.appending(path: "StagedImageCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: stagedDirectory)
		stagedDirectory = nil
		repository = nil
		deep = nil
		dataController = nil
		try await super.tearDown()
	}

	private func makeCapture(staged: [String]) -> StagedImageCapture {
		StagedImageCapture(
			deep: deep,
			settings: Settings(),
			repository: repository,
			authState: AuthState(provider: MockAuthProvider(outcome: .ready)),
			stagedNames: staged,
			stagedDirectory: stagedDirectory
		)
	}

	/// Writes a real 10×10 PNG under `name` in the staging directory.
	private func stageImage(named name: String) throws {
		let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
			UIColor.gray.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
		}
		let data = try XCTUnwrap(image.pngData())
		try data.write(to: stagedDirectory.appending(path: name))
	}

	private func registerDetector(labels: [String]) {
		deep.drivers.register(
			driver: FixedObjectsDetecting(
				params: DeepDriverParams(entityId: UUID(), modelName: "Stub"),
				objects: labels.map { label in
					DetectedObject(
						uuid: UUID(),
						labels: [DetectedObject.Label(identifier: label, confidence: 0.9)],
						confidence: 0.734,
						boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
						regionIndex: 0
					)
				}
			),
			along: .detector
		)
	}

	func test_detect_refusesANameThatWasNotStaged_evenIfTheFileExists() async throws {
		try stageImage(named: "other.png")
		let capture = makeCapture(staged: ["terrain.png"])
		do {
			_ = try await capture.detect(imageNamed: "other.png")
			XCTFail("an unlisted name must be refused")
		} catch {
			XCTAssertEqual(error as? StagedImageCapture.Failure, .notStaged)
		}
		XCTAssertNil(capture.frame)
	}

	func test_detect_aStagedNameWithNoFile_isAMissingFile() async {
		let capture = makeCapture(staged: ["terrain.png"])
		do {
			_ = try await capture.detect(imageNamed: "terrain.png")
			XCTFail("a missing file must fail")
		} catch {
			XCTAssertEqual(error as? StagedImageCapture.Failure, .missingFile)
		}
	}

	func test_detect_aFileThatIsNotAnImage_isUndecodable() async throws {
		try Data("not an image".utf8).write(to: stagedDirectory.appending(path: "terrain.png"))
		let capture = makeCapture(staged: ["terrain.png"])
		do {
			_ = try await capture.detect(imageNamed: "terrain.png")
			XCTFail("an undecodable file must fail")
		} catch {
			XCTAssertEqual(error as? StagedImageCapture.Failure, .undecodableImage)
		}
	}

	func test_detect_flattensInDriverOrder_thenObservationOrder() async throws {
		try stageImage(named: "terrain.png")
		registerDetector(labels: ["first-a", "first-b"])
		registerDetector(labels: ["second-a"])
		let capture = makeCapture(staged: ["terrain.png"])

		let detections = try await capture.detect(imageNamed: "terrain.png")

		XCTAssertEqual(detections.map(\.index), [0, 1, 2])
		XCTAssertEqual(detections.map(\.label), ["first-a", "first-b", "second-a"])
		XCTAssertEqual(detections.first?.confidence ?? 0, 0.734, accuracy: 0.0001, "the observation's confidence, not the label's")
		XCTAssertNotNil(capture.frame)
		XCTAssertNil(capture.pendingCapture)
	}

	func test_pick_outOfRange_isRefused_andNothingIsPending() async throws {
		try stageImage(named: "terrain.png")
		registerDetector(labels: ["only"])
		let capture = makeCapture(staged: ["terrain.png"])
		_ = try await capture.detect(imageNamed: "terrain.png")

		XCTAssertThrowsError(try capture.pick(index: 1)) { error in
			XCTAssertEqual(error as? StagedImageCapture.Failure, .detectionOutOfRange)
		}
		XCTAssertThrowsError(try capture.pick(index: -1)) { error in
			XCTAssertEqual(error as? StagedImageCapture.Failure, .detectionOutOfRange)
		}
		XCTAssertNil(capture.pendingCapture)
	}

	func test_pick_beforeAnyDetection_hasNoFrame() {
		XCTAssertThrowsError(try makeCapture(staged: []).pick(index: 0)) { error in
			XCTAssertEqual(error as? StagedImageCapture.Failure, .noFrame)
		}
	}

	func test_save_withoutAPick_isRefused() {
		XCTAssertThrowsError(try makeCapture(staged: []).save(title: "Mound")) { error in
			XCTAssertEqual(error as? StagedImageCapture.Failure, .noPendingCapture)
		}
	}

	func test_pickThenSave_persistsTheFinding_andClosesTheSheet() async throws {
		try stageImage(named: "terrain.png")
		registerDetector(labels: ["mound", "barrow"])
		let capture = makeCapture(staged: ["terrain.png"])
		_ = try await capture.detect(imageNamed: "terrain.png")

		try capture.pick(index: 1)
		XCTAssertEqual(capture.pendingCapture?.observation.primaryLabelIdentifier, "barrow")
		let id = try capture.save(title: "  Barrow  ", label: "tumulus")

		XCTAssertNil(capture.pendingCapture)
		let finding = try XCTUnwrap(Finding.select(id, in: dataController.container.viewContext))
		defer { FindingScreenshotStore.delete(filename: finding.screenshotFilename) }
		XCTAssertEqual(finding.title, "Barrow")
		XCTAssertEqual(finding.detectionClass, "barrow")
		XCTAssertNil(finding.page, "a staged image comes from no page")
	}

	func test_cancel_dropsThePendingCapture() async throws {
		try stageImage(named: "terrain.png")
		registerDetector(labels: ["mound"])
		let capture = makeCapture(staged: ["terrain.png"])
		_ = try await capture.detect(imageNamed: "terrain.png")
		try capture.pick(index: 0)

		capture.cancel()

		XCTAssertNil(capture.pendingCapture)
		XCTAssertNotNil(capture.frame, "cancelling closes the sheet, not the detections")
	}
}

/// A `Detecting` conformer returning fixed objects, so the real `DeepDrivers` → `DetectionEngine`
/// orchestration runs without a model. Not private: `HeadlessWalkTests` detects with it too.
actor FixedObjectsDetecting: Detecting {
	let id: UUID
	var params: DeepDriverParams
	var observations: [VNObservation] = []
	private let objects: [DetectedObject]

	init(params: DeepDriverParams, objects: [DetectedObject]) {
		self.id = params.entityId
		self.params = params
		self.objects = objects
	}

	func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] { objects }
	func metadata() -> [MLModelMetadataKey: Any]? { nil }
	func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
	func process(image: UIImage) async {}
	func loadFile() async throws {}
	func run() async {}
	func unload() async {}
}
