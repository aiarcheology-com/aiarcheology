//
//  FindingsSyncCycleTests.swift
//  MLBrowserUnitTests
//
//  AIA-727: a full push/pull cycle against a stubbed Worker.
//

import CoreData
import UIKit
import XCTest
@testable import ML_Browser

/// Answers HTTP for the sync tests, and records what was asked.
///
/// A stub at the URL layer rather than a fake transport: the request building, the query
/// parameters, the JSON decoding and the error contract are all things that can be wrong, and a
/// hand-written fake transport would test none of them.
final class StubWorkerProtocol: URLProtocol {
	nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
	nonisolated(unsafe) static var requests: [String] = []

	/// JSON for a stubbed response. A helper rather than `try!` at each call site: a lint rule bans
	/// force-try, and an unencodable literal here is a bug in the test, not something to crash on.
	static func json(_ object: Any) -> Data {
		(try? JSONSerialization.data(withJSONObject: object)) ?? Data()
	}

	static func reset() {
		handler = nil
		requests = []
	}

	static var session: URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubWorkerProtocol.self]
		return URLSession(configuration: configuration)
	}

	override static func canInit(with request: URLRequest) -> Bool { true }
	override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let method = request.httpMethod ?? "GET"
		let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
		Self.requests.append("\(method) \(path)")

		let (status, body) = Self.handler?(request) ?? (500, Data())
		let response = HTTPURLResponse(
			url: request.url!,
			statusCode: status,
			httpVersion: "HTTP/1.1",
			headerFields: ["content-type": "application/json"]
		)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

@MainActor
final class FindingsSyncCycleTests: XCTestCase {

	private var dataController: DataController!
	private var repository: FindingRepository!
	private var auth: MockAuthProvider!
	private var scratch: URL!
	private var sut: FindingsSync!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		StubWorkerProtocol.reset()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		repository = FindingRepository(dataController: dataController)
		auth = MockAuthProvider(outcome: .ready, accountID: "user_cycle_\(UUID().uuidString.prefix(8))")
		scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		sut = FindingsSync(
			authProvider: auth,
			findingRepository: repository,
			context: moc,
			transportFactory: { url in
				FindingsCloudTransport(baseURL: url, session: StubWorkerProtocol.session) { "stub.token" }
			},
			ledgerDirectory: scratch
		)
	}

	override func tearDown() async throws {
		StubWorkerProtocol.reset()
		try? FileManager.default.removeItem(at: scratch)
		try await super.tearDown()
	}

	// MARK: - Helpers

	private func manifest(id: UUID, title: String, modifiedAt: Int64) throws -> Data {
		let snapshot = FindingSnapshot(
			id: id,
			title: title,
			confidence: 0.9,
			box: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			modifiedAt: Date(timeIntervalSince1970: Double(modifiedAt) / 1000),
			lifeCycle: CoreDataManageableState.ready.rawValue
		)
		return try FindingExporter.encodeJSON([snapshot], copiedImageNames: [:])
	}

	private func makeImage(_ side: Int = 12) -> UIImage {
		UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
			UIColor.darkGray.setFill()
			ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
		}
	}

	/// Saves through the production path, so what sync uploads is a real row.
	@discardableResult
	private func saveFinding(title: String) throws -> Finding {
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let capture = FindingCapture(
			observation: DetectedObject(uuid: UUID(), labels: [], confidence: 0.9, boundingBox: box, regionIndex: 0),
			params: nil,
			frame: AppliedDetectionFrame(image: makeImage(), results: []),
			pageURL: URL(string: "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren")
		)
		return try repository.save(
			capture: capture,
			image: makeImage(),
			box: box,
			metadata: FindingMetadata(title: title, label: "", note: "", author: "", gps: "")
		)
	}

	private func storedFinding(_ id: UUID) -> Finding? { Finding.select(id, in: moc) }

	// MARK: - Pull

	func testAFindingPulledFromTheCloudIsNotImmediatelyPushedBackUp() async throws {
		// The failure this guards is a loop, not a crash: a fresh install downloads N findings,
		// pushes all N back with a new receipt each, and every other device pulls the whole stream
		// again. It costs the user bandwidth for ever and looks like sync "never settling".
		let id = UUID()
		let modifiedAt: Int64 = 1_700_000_000_000
		let manifest = try manifest(id: id, title: "A ditch", modifiedAt: modifiedAt)
		StubWorkerProtocol.handler = { [manifest] request in
			let path = request.url?.path ?? ""
			if path.hasSuffix("/meta") { return (200, manifest) }
			return (200, StubWorkerProtocol.json([
				"findings": request.url?.query?.contains("cursor") == true ? [] : [[
					"id": id.uuidString, "modifiedAt": modifiedAt, "receivedAt": modifiedAt + 1,
					"deleted": false, "bytes": 512, "hasImage": false
				]],
				"nextCursor": "1.\(id.uuidString)",
				"hasMore": false,
				"usage": ["used": 512, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertNotNil(storedFinding(id), "the cloud copy should have been applied locally")

		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value

		let writes = StubWorkerProtocol.requests.filter { $0.hasPrefix("PUT") }
		XCTAssertTrue(writes.isEmpty, "the finding was pushed straight back: \(writes)")
	}

	func testALocalFindingNewerThanTheCloudCopySurvivesThePull() async throws {
		// Last-write-wins in the direction that is easy to get backwards. Applying an older cloud
		// copy over a newer local edit would silently discard the user's most recent work.
		let finding = try saveFinding(title: "The local one")
		let id = finding.entityId
		let localMilliseconds = FindingsSync.milliseconds(finding.modifiedAt ?? Date())

		StubWorkerProtocol.handler = { request in
			let path = request.url?.path ?? ""
			if path.hasSuffix("/meta"), request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": id.uuidString, "modifiedAt": localMilliseconds,
						"receivedAt": localMilliseconds + 1, "deleted": false,
						"bytes": 512, "hasImage": true
					],
					"usage": ["used": 512, "limit": 52_428_800]
				]))
			}
			if path.hasSuffix("/image") { return (200, Data()) }
			return (200, StubWorkerProtocol.json([
				"findings": [[
					"id": id.uuidString, "modifiedAt": localMilliseconds - 60_000,
					"receivedAt": localMilliseconds, "deleted": false,
					"bytes": 512, "hasImage": false
				]],
				"nextCursor": "1.a", "hasMore": false,
				"usage": ["used": 512, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertEqual(storedFinding(id)?.displayTitle, "The local one")
	}

	// MARK: - Push

	func testTheServersClampedTimestampIsAdoptedRatherThanArguedWith() async throws {
		// A device with a fast clock has its timestamp clamped to receipt time. Keeping the local
		// value would make the finding look permanently newer than the cloud's copy, and it would
		// be re-uploaded on every single sync.
		let finding = try saveFinding(title: "Fast clock")
		let id = finding.entityId
		finding.preservesModifiedAt = true
		let future = Date().addingTimeInterval(3_600)
		finding.modifiedAt = future
		try Finding.save(in: moc)
		finding.preservesModifiedAt = false

		// Findings that predate this account are held for an explicit answer, so the push these two
		// tests are about only happens once the question has been answered.
		let clamped = FindingsSync.milliseconds(Date())
		StubWorkerProtocol.handler = { request in
			let path = request.url?.path ?? ""
			if path.hasSuffix("/meta"), request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": id.uuidString, "modifiedAt": clamped, "receivedAt": clamped + 1,
						"deleted": false, "bytes": 512, "hasImage": true
					],
					"usage": ["used": 512, "limit": 52_428_800]
				]))
			}
			if path.hasSuffix("/image") {
				return (200, StubWorkerProtocol.json([
					"modifiedAt": clamped, "bytes": 512, "usage": ["used": 512, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 512, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertEqual(sut.findingsAwaitingBackupConsent, 1, "the pre-existing finding should be held for consent")
		await sut.answerBackupConsent(accepted: true)?.value

		let stored = try XCTUnwrap(storedFinding(id))
		XCTAssertEqual(FindingsSync.milliseconds(stored.modifiedAt ?? .distantPast), clamped)
	}

	func testDeletingAFindingSendsATombstone() async throws {
		let finding = try saveFinding(title: "Doomed")
		let id = finding.entityId

		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "DELETE" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": id.uuidString, "modifiedAt": 1, "receivedAt": 2,
						"deleted": true, "bytes": 0, "hasImage": false
					],
					"usage": ["used": 0, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		try repository.delete(finding)
		// A delete has to reach the cloud, or every other device keeps a finding the user removed.
		await sut.syncNow()?.value

		let deletes = StubWorkerProtocol.requests.filter { $0.hasPrefix("DELETE") }
		XCTAssertEqual(deletes.count, 1, "expected exactly one tombstone, got \(StubWorkerProtocol.requests)")
		XCTAssertTrue(deletes.first?.contains(id.uuidString) == true, "got \(deletes)")
	}
}
