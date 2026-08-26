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
	private var sut: FindingsSyncCoordinator!
	private var tracker: RecordingAnalyticsTracker!
	private var moc: NSManagedObjectContext { dataController.container.viewContext }

	override func setUp() async throws {
		try await super.setUp()
		StubWorkerProtocol.reset()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		repository = FindingRepository(dataController: dataController)
		auth = MockAuthProvider(outcome: .ready, accountID: "user_cycle_\(UUID().uuidString.prefix(8))")
		scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		tracker = RecordingAnalyticsTracker()
		let settings = Settings()
		let flags = FeatureFlagsState(provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: true]))
		let analytics = AnalyticsState(
			settings: settings,
			tracker: tracker,
			featureFlags: flags,
			isAccountIdentityEnabled: true
		)
		analytics.updateAccountIdentity("user_2aaaaaaaaaaaaaaaaaaaaaaaaa")
		// Consent is per account (AIA-0437) and nothing is sent without it, so these tests answer
		// the question the same way a consenting user would. What is asserted below is what sync
		// reports when it is allowed to report anything at all.
		analytics.chooseAnalytics(enabled: true)
		sut = FindingsSyncCoordinator(
			authProvider: auth,
			analytics: analytics,
			findingRepository: repository,
			dataController: dataController,
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
		let localMilliseconds = FindingsSyncCoordinator.milliseconds(finding.modifiedAt ?? Date())

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
		let clamped = FindingsSyncCoordinator.milliseconds(Date())
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
		XCTAssertNil(sut.backupConsentRequest, "the account made this finding here; nothing to ask")

		let stored = try XCTUnwrap(storedFinding(id))
		XCTAssertEqual(FindingsSyncCoordinator.milliseconds(stored.modifiedAt ?? .distantPast), clamped)
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

// MARK: - What sync is allowed to report

extension FindingsSyncCycleTests {

	func testACompletedCycleReportsThatSyncIsUsed_andNothingPerFinding() async throws {
		// Two account-scoped signals, and deliberately nothing per finding: a per-finding event
		// would be a record of how often somebody surveys, which is not ours to collect.
		let id = UUID()
		let modifiedAt: Int64 = 1_700_000_000_000
		let manifest = try manifest(id: id, title: "A ditch", modifiedAt: modifiedAt)
		StubWorkerProtocol.handler = { request in
			if request.url?.path.hasSuffix("/meta") == true { return (200, manifest) }
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
		XCTAssertEqual(tracker.events, [.cloudSyncEnabled])

		// A second cycle says nothing new: the signal is that the account syncs at all.
		await sut.syncNow()?.value
		XCTAssertEqual(tracker.events, [.cloudSyncEnabled])
	}

	func testRunningOutOfCloudStorageIsReportedOnceForAsLongAsItLasts() async throws {
		try saveFinding(title: "Too big for the account")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT" {
				return (507, StubWorkerProtocol.json([
					"error": [
						"code": "quota_exceeded",
						"message": "full",
						"retryable": false
					]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 52_428_800, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertEqual(tracker.events.filter { $0 == .cloudSyncQuotaBlocked }.count, 1)

		await sut.syncNow()?.value
		XCTAssertEqual(
			tracker.events.filter { $0 == .cloudSyncQuotaBlocked }.count, 1,
			"the account being full is one event, not one per attempt"
		)
	}
}

// MARK: - Whose findings are these

extension FindingsSyncCycleTests {

	/// Saves a finding while nobody is signed in, so the store holds work this account did not make
	/// — the shared-device case.
	private func saveFindingBelongingToNobody(title: String) throws -> Finding {
		auth.setOutcomeForTesting(.signedOut)
		defer { auth.setOutcomeForTesting(.ready) }
		return try saveFinding(title: title)
	}

	func testAFindingThisAccountDidNotMakeIsNotUploadedWithoutAnAnswer() async throws {
		let stranger = try saveFindingBelongingToNobody(title: "Somebody else's dig")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value

		XCTAssertEqual(sut.backupConsentRequest?.ids, [stranger.entityId])
		XCTAssertTrue(
			StubWorkerProtocol.requests.filter { $0.hasPrefix("PUT") }.isEmpty,
			"nothing may leave the device before the question is answered"
		)
	}

	func testAnAnswerAppliesOnlyToTheFindingsItWasGivenFor() async throws {
		// The hole this closes: one "yes" used to authorise every finding that ever appeared on the
		// device afterwards, including another account's.
		let first = try saveFindingBelongingToNobody(title: "The one that was asked about")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT", request.url?.path.hasSuffix("/meta") == true {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": UUID().uuidString, "modifiedAt": 1, "receivedAt": 2,
						"deleted": false, "bytes": 1, "hasImage": false
					],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			if request.url?.path.hasSuffix("/image") == true {
				return (200, StubWorkerProtocol.json([
					"modifiedAt": 1, "bytes": 1, "usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertEqual(sut.backupConsentRequest?.ids, [first.entityId])
		await sut.answerBackupConsent(accepted: true)?.value

		// A second stranger arrives afterwards. The earlier yes says nothing about it.
		let second = try saveFindingBelongingToNobody(title: "Arrived after the answer")
		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value

		XCTAssertEqual(sut.backupConsentRequest?.ids, [second.entityId])
		let uploadedIds = StubWorkerProtocol.requests.filter { $0.hasPrefix("PUT") }
		XCTAssertTrue(
			uploadedIds.allSatisfy { $0.contains(second.entityId.uuidString) == false },
			"the second finding must not ride in on the first one's answer: \(uploadedIds)"
		)
	}

	func testDecliningIsRememberedRatherThanAskedAgainEveryLaunch() async throws {
		let stranger = try saveFindingBelongingToNobody(title: "Not mine")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertEqual(sut.backupConsentRequest?.ids, [stranger.entityId])
		await sut.answerBackupConsent(accepted: false)?.value

		await sut.syncNow()?.value
		XCTAssertNil(sut.backupConsentRequest, "declining is an answer, not a deferral")
	}

	// MARK: - Saying yes later (AIA-740)

	func testBackUpNowUploadsFindingsThatWereDeclinedEarlier() async throws {
		let stranger = try saveFindingBelongingToNobody(title: "Declined in haste")
		// The id, not the object: `Finding` is not Sendable and the stub handler is.
		let strangerId = stranger.entityId.uuidString
		StubWorkerProtocol.handler = { request in
			// Each leg answers in its own shape. A response the transport cannot decode is a
			// transport failure, which the outcome assertion below would then report as "offline"
			// -- so an incomplete stub here fails this test for the wrong reason.
			if request.httpMethod == "PUT", request.url?.path.hasSuffix("/meta") == true {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": strangerId, "modifiedAt": 1, "receivedAt": 2,
						"deleted": false, "bytes": 1, "hasImage": false
					],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			if request.url?.path.hasSuffix("/image") == true {
				return (200, StubWorkerProtocol.json([
					"modifiedAt": 1, "bytes": 1, "usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		await sut.answerBackupConsent(accepted: false)?.value

		// Nothing may go up on its own after a decline -- that part must keep working.
		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") } == false,
			"a declined finding must not upload by itself: \(StubWorkerProtocol.requests)"
		)

		// ...until the user says so explicitly. Before AIA-740 this was unreachable: `excluded` was
		// only ever cleared by accepting a prompt, and a prompt was only raised for findings that
		// were not already excluded, so no route back existed at all.
		StubWorkerProtocol.requests = []
		await sut.backUpNow(expectedAccount: try XCTUnwrap(auth.accountIdentifier))?.value

		XCTAssertTrue(
			StubWorkerProtocol.requests.contains {
				$0.hasPrefix("PUT") && $0.contains(strangerId) && $0.contains("/meta")
			},
			// `contains`, not `hasSuffix`: the recorded request keeps its `?modifiedAt=` query.
			"pressing Back Up must COMMIT the finding declined earlier -- the image leg alone does "
				+ "not make it visible to another device: \(StubWorkerProtocol.requests)"
		)
		XCTAssertEqual(sut.lastManualBackup, .succeeded, "the user pressed a button and is owed an answer")
		XCTAssertFalse(sut.isBackingUp, "the busy flag must clear when the back-up ends")
	}

	func testBackUpNowSaysTheAccountIsFullRatherThanBlamingTheNetwork() async throws {
		try saveFinding(title: "No room for this one")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT" {
				return (507, StubWorkerProtocol.json([
					"error": ["code": "quota_exceeded", "message": "full", "retryable": false]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 52_428_800, "limit": 52_428_800]
			]))
		}

		await sut.backUpNow(expectedAccount: try XCTUnwrap(auth.accountIdentifier))?.value

		// Running out of room is not a failed cycle and not a network problem: the upload is refused
		// permanently and parked, and the cycle completes. Reporting either of the other two would
		// send the user to check their signal, which cannot help.
		XCTAssertEqual(sut.lastManualBackup, .quotaFull)
		XCTAssertTrue(sut.isQuotaBlocked, "the button reads this to stop looking like it will work")
	}

	// MARK: - Turning back-up off (AIA-744)

	func testTurningBackUpOffStopsFindingsCreatedAfterwardsFromUploading() async throws {
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT", request.url?.path.hasSuffix("/meta") == true {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": UUID().uuidString, "modifiedAt": 1, "receivedAt": 2,
						"deleted": false, "bytes": 1, "hasImage": false
					],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			if request.url?.path.hasSuffix("/image") == true {
				return (200, StubWorkerProtocol.json([
					"modifiedAt": 1, "bytes": 1, "usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)

		await sut.setBackUpEnabled(false, expectedAccount: account)?.value
		XCTAssertFalse(sut.isBackUpEnabled)

		// The case that made the missing switch confusing: a finding created while signed in is the
		// account's by construction, so it used to upload no matter what the user had answered.
		try saveFinding(title: "Made while back-up is off")
		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value

		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") } == false,
			"nothing may leave the device while back-up is off: \(StubWorkerProtocol.requests)"
		)

		// ...and turning it back on sends what accumulated, without needing the button.
		StubWorkerProtocol.requests = []
		await sut.setBackUpEnabled(true, expectedAccount: account)?.value

		XCTAssertTrue(sut.isBackUpEnabled)
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") && $0.contains("/meta") },
			"turning back-up on uploads what was withheld: \(StubWorkerProtocol.requests)"
		)
	}

	func testTurningBackUpOffStillPullsSoAReinstallCanRestore() async throws {
		let remote = UUID()
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "GET", request.url?.path.hasSuffix("/meta") == true {
				return (200, StubWorkerProtocol.json([
					"findings": [[
						"id": remote.uuidString, "title": "From the cloud",
						"lifeCycle": "ready", "date": "2026-08-26T10:00:00Z"
					]],
					"schemaVersion": 1
				]))
			}
			if request.httpMethod == "GET" {
				return (200, StubWorkerProtocol.json([
					"findings": [[
						"id": remote.uuidString, "modifiedAt": 5, "receivedAt": 7,
						"deleted": false, "bytes": 10, "hasImage": false
					]],
					"nextCursor": NSNull(), "hasMore": false,
					"usage": ["used": 10, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)

		await sut.setBackUpEnabled(false, expectedAccount: account)?.value
		await sut.syncNow()?.value

		// Off means "stop sending", not "forget what is already backed up". A user who turns it off
		// and then reinstalls must still get their work back -- withholding it would be the worse
		// surprise, and deleting the account is the way to remove a backup.
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("GET") },
			"the pull still runs while back-up is off: \(StubWorkerProtocol.requests)"
		)
	}

	func testBackUpNowClearsTheStandingQuestionRatherThanLeavingItOnScreen() async throws {
		_ = try saveFindingBelongingToNobody(title: "Asked about")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": ["id": UUID().uuidString, "modifiedAt": 1, "deleted": false],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertNotNil(sut.backupConsentRequest, "the prompt is the precondition for this test")

		await sut.backUpNow(expectedAccount: try XCTUnwrap(auth.accountIdentifier))?.value

		XCTAssertNil(
			sut.backupConsentRequest,
			"pressing Back Up answers the question; leaving it up would ask something already agreed"
		)
	}
}

// MARK: - Reading the store that is actually there

extension FindingsSyncCycleTests {

	func testSyncStillSeesFindingsAfterTheStoreIsRebuilt() async throws {
		// The failure this guards produced no error and no crash: a migration that cannot find its
		// mapping model makes `DataController` destroy the store and build a FRESH container, on a
		// later main-queue turn. Anything holding the old `viewContext` then queries a store that no
		// longer exists -- every fetch returns nothing, so sync reports "pending 0" and uploads
		// nothing while the app happily shows the user their findings.
		//
		// `FindingRepository` computes its context for exactly this reason; the coordinator used to
		// capture it once.
		try saveFinding(title: "Recorded before the rebuild")
		XCTAssertEqual(Finding.count(in: moc, predicate: nil), 1)

		// Stand in for the recovery: replace the container the way `DataController` does.
		await dataController.replaceContainerForTesting()

		let afterRebuild = try saveFinding(title: "Recorded after the rebuild").entityId

		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT", request.url?.path.hasSuffix("/meta") == true {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": UUID().uuidString, "modifiedAt": 1, "receivedAt": 2,
						"deleted": false, "bytes": 1, "hasImage": false
					],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			if request.url?.path.hasSuffix("/image") == true {
				return (200, StubWorkerProtocol.json([
					"modifiedAt": 1, "bytes": 1, "usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value

		// The finding made after the rebuild is this account's own work, so it needs no consent and
		// must reach the cloud. A coordinator holding the dead context uploads nothing at all.
		// Asserted on THIS finding, not merely on "something was uploaded": a coordinator holding
		// the old context can still see rows in the store it was built against, so any-upload would
		// pass while the live store went unread.
		let uploads = StubWorkerProtocol.requests.filter { $0.hasPrefix("PUT") }
		XCTAssertTrue(
			uploads.contains { $0.contains(afterRebuild.uuidString) },
			"the finding saved after the rebuild never reached the cloud: \(uploads)"
		)
	}
	// MARK: - AIA-0752 — what the epic review found

	/// A delete has to reach the cloud even with backing up switched off.
	///
	/// Gating tombstones behind the switch left a user who had turned back-up off unable to remove
	/// anything from the account at all — while "Remove all findings" promises permanent deletion,
	/// and the privacy policy says a deleted finding is deleted from the backup too.
	func testATombstoneIsSentEvenWhenBackingUpIsSwitchedOff() async throws {
		let finding = try saveFinding(title: "Gone, and it must stay gone")
		let id = finding.entityId
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "DELETE" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": id.uuidString, "modifiedAt": 9, "receivedAt": 9,
						"deleted": true, "bytes": 0, "hasImage": false
					],
					"usage": ["used": 0, "limit": 52_428_800]
				]))
			}
			if request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": id.uuidString, "modifiedAt": 1, "receivedAt": 2,
						"deleted": false, "bytes": 1, "hasImage": false
					],
					"usage": ["used": 1, "limit": 52_428_800]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)
		await sut.syncNow()?.value

		await sut.setBackUpEnabled(false, expectedAccount: account)?.value
		StubWorkerProtocol.requests = []
		try repository.delete(finding)
		await sut.syncNow()?.value

		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("DELETE") },
			"Turning backing up off must not strand a delete on the device: \(StubWorkerProtocol.requests)"
		)
	}

	/// Freeing room has to lift the block, because that is the advice the app gives.
	func testDeletingAFindingLiftsTheStorageFullBlock() async throws {
		let doomed = try saveFinding(title: "Takes the last of the room")
		let doomedId = doomed.entityId
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "DELETE" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": doomedId.uuidString, "modifiedAt": 9, "receivedAt": 9,
						"deleted": true, "bytes": 0, "hasImage": false
					],
					"usage": ["used": 0, "limit": 52_428_800]
				]))
			}
			if request.httpMethod == "PUT" {
				return (507, StubWorkerProtocol.json([
					"error": ["code": "quota_exceeded", "message": "full", "retryable": false]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 52_428_800, "limit": 52_428_800]
			]))
		}
		await sut.syncNow()?.value
		XCTAssertTrue(sut.isQuotaBlocked, "The upload was refused for room, so the block should be up")

		try repository.delete(doomed)
		await sut.syncNow()?.value

		XCTAssertFalse(
			sut.isQuotaBlocked,
			"Removing a finding is exactly what the app tells the user to do, so it has to clear the block"
		)
		XCTAssertEqual(sut.parkedCount, 0, "A park recorded against a deleted finding is a ghost")
	}

	/// The answer to the consent card must survive the cycle that raised it.
	///
	/// The card is raised from inside a running cycle, so the user answers while that cycle still
	/// holds a copy of the ledger from before the answer existed. Writing the answer straight to
	/// disk let that cycle's own save put the exclusions back — decline came round asking again,
	/// and accept uploaded nothing.
	func testDecliningTheCardSurvivesACycleThatWasAlreadyRunning() async throws {
		try saveFindingBelongingToNobody(title: "Not mine to upload")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		await sut.syncNow()?.value
		XCTAssertNotNil(sut.backupConsentRequest, "The stranger's finding should have raised the card")

		// Answer, and start another cycle in the same breath — the interleaving the bug needed.
		let answering = sut.answerBackupConsent(accepted: false)
		let racing = sut.syncNow()
		await answering?.value
		await racing?.value
		await sut.syncNow()?.value

		XCTAssertNil(
			sut.backupConsentRequest,
			"The decline was recorded, so nothing should ask about those findings again"
		)
		XCTAssertFalse(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") },
			"A declined finding must never be uploaded: \(StubWorkerProtocol.requests)"
		)
	}

	/// Sync must not carry one account's fieldwork into the session that replaced it.
	///
	/// The credential fence stops an upload going to the wrong account. This is the other
	/// direction: a download authorised for A, landing after B has signed in.
	func testAFindingDownloadedForOneAccountIsNotImportedAfterAnotherSignsIn() async throws {
		let incoming = UUID()
		let body = try manifest(id: incoming, title: "A's dig", modifiedAt: 1_000)
		let auth = try XCTUnwrap(self.auth)
		// The switch has to land WHILE the metadata request is in flight, which is the only moment
		// the bug needed. The stub runs off the main actor, so it hands the change to the main actor
		// and waits for it — deterministic, where firing and hoping would be a flaky test.
		let switched = DispatchSemaphore(value: 0)
		StubWorkerProtocol.handler = { [body] request in
			if request.url?.path.contains("/meta") == true {
				Task { @MainActor in
					auth.setOutcomeForTesting(.signedOut)
					switched.signal()
				}
				switched.wait()
				return (200, body)
			}
			return (200, StubWorkerProtocol.json([
				"findings": [[
					"id": incoming.uuidString, "modifiedAt": 1_000, "receivedAt": 1,
					"deleted": false, "bytes": 10, "hasImage": false
				]],
				"nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 10, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value

		XCTAssertNil(
			storedFinding(incoming),
			"A finding fetched for one account must not land in the store once another is signed in"
		)
	}

	/// An account switch mid-download must not spend this account's cursor.
	///
	/// Refusing the import was only half of it: reporting the row as "dealt with" moved the cursor
	/// past a finding this device never received, so signing back in would never fetch it again —
	/// the cross-account leak swapped for permanent per-device loss.
	func testAnAccountSwitchMidDownloadLeavesTheCursorWhereItWas() async throws {
		let incoming = UUID()
		let body = try manifest(id: incoming, title: "A's dig", modifiedAt: 1_000)
		let auth = try XCTUnwrap(self.auth)
		let switched = DispatchSemaphore(value: 0)
		StubWorkerProtocol.handler = { [body] request in
			if request.url?.path.contains("/meta") == true {
				Task { @MainActor in
					auth.setOutcomeForTesting(.signedOut)
					switched.signal()
				}
				switched.wait()
				return (200, body)
			}
			return (200, StubWorkerProtocol.json([
				"findings": [[
					"id": incoming.uuidString, "modifiedAt": 1_000, "receivedAt": 77,
					"deleted": false, "bytes": 10, "hasImage": false
				]],
				"nextCursor": "77.\(incoming.uuidString)", "hasMore": false,
				"usage": ["used": 10, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)

		await sut.syncNow()?.value

		auth.setOutcomeForTesting(.ready)
		let ledger = await FindingsSyncLedgerStore(accountIdentifier: account, directory: scratch).loadLedger()
		XCTAssertNil(
			ledger.cursor,
			"The row was never applied, so the cursor must not have moved past it: \(String(describing: ledger.cursor))"
		)
	}

	/// A row this build cannot decode must not block every finding behind it.
	///
	/// The counterpart — a Core Data save that failed because the disk is full — is deliberately
	/// NOT skipped, because it is about this device rather than this finding and it clears. That
	/// half has no test: inducing a store failure under the real repository is not something this
	/// harness can do, so it rests on the catch clauses being exhaustive by type.
	func testARowThisBuildCannotDecodeDoesNotBlockEveryFindingBehindIt() async throws {
		let incoming = UUID()
		// Metadata that parses as JSON but is not a findings manifest. `decodeRows` wraps the
		// decoding failure into `FindingArchiveImportError.malformedManifest`, which is
		// deterministic, so this row is allowed to be skipped and the cursor to move past it.
		let body = StubWorkerProtocol.json(["not": "a manifest"])
		StubWorkerProtocol.handler = { [body] request in
			if request.url?.path.contains("/meta") == true { return (200, body) }
			return (200, StubWorkerProtocol.json([
				"findings": [[
					"id": incoming.uuidString, "modifiedAt": 1_000, "receivedAt": 88,
					"deleted": false, "bytes": 10, "hasImage": false
				]],
				"nextCursor": "88.\(incoming.uuidString)", "hasMore": false,
				"usage": ["used": 10, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)

		await sut.syncNow()?.value

		let ledger = await FindingsSyncLedgerStore(accountIdentifier: account, directory: scratch).loadLedger()
		XCTAssertNotNil(
			ledger.cursor,
			"A row this build can never decode must not block every finding behind it for ever"
		)
		XCTAssertNil(storedFinding(incoming), "Nothing decodable arrived, so nothing should be stored")
	}

	/// A decline survives a cycle that is interrupted before it can persist anything.
	///
	/// Signing out mid-cycle makes the cycle return at its account guard, so the answer it claimed
	/// goes back on the queue rather than being discarded — the finding must still not upload when
	/// the account comes back.
	///
	/// NOTE ON WHAT THIS DOES NOT COVER. The dangerous case is two answers of OPPOSITE polarity
	/// meeting in that re-queue: an entry carries a single `accepted`, so merging an older decline
	/// into a newer acceptance would stamp the acceptance onto the declined findings and upload a
	/// name, coordinates and a photograph the user had refused. `requeue` therefore drops the older
	/// claim on a mismatch instead of merging. Three attempts to drive that branch from here failed
	/// — the second card is not raised at the moment the stub can answer it — so that branch is
	/// argued, not pinned. If you touch `requeue`, read it rather than trusting this suite.
	func testADeclineSurvivesACycleInterruptedBeforeItCouldSave() async throws {
		let declined = try saveFindingBelongingToNobody(title: "Declined, and it must stay declined")
		let declinedId = declined.entityId
		let emptyPage = StubWorkerProtocol.json([
			"findings": [], "nextCursor": NSNull(), "hasMore": false,
			"usage": ["used": 0, "limit": 52_428_800]
		])
		StubWorkerProtocol.handler = { [emptyPage] _ in (200, emptyPage) }

		await sut.syncNow()?.value
		XCTAssertEqual(sut.backupConsentRequest?.ids, [declinedId])
		sut.answerBackupConsent(accepted: false)

		// A second unclaimed finding, so the next cycle raises a card of its own.
		try saveFindingBelongingToNobody(title: "This one is fine to upload")

		let sut = try XCTUnwrap(self.sut)
		let auth = try XCTUnwrap(self.auth)
		let interrupted = DispatchSemaphore(value: 0)
		StubWorkerProtocol.handler = { [emptyPage] request in
			guard request.httpMethod == "GET", request.url?.path.hasSuffix("/findings") == true else {
				return (200, emptyPage)
			}
			// Push has already raised the card for the second finding. Answer it — queuing the
			// newer, opposite answer — and then sign out, so the cycle leaves without saving and
			// the decline it claimed goes back on the queue beside it.
			Task { @MainActor in
				sut.answerBackupConsent(accepted: true)
				auth.setOutcomeForTesting(.signedOut)
				interrupted.signal()
			}
			interrupted.wait()
			return (200, emptyPage)
		}
		await sut.syncNow()?.value

		auth.setOutcomeForTesting(.ready)
		StubWorkerProtocol.handler = { [emptyPage] _ in (200, emptyPage) }
		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value
		await sut.syncNow()?.value

		let uploaded = StubWorkerProtocol.requests.filter { $0.hasPrefix("PUT") }
		XCTAssertFalse(
			uploaded.contains { $0.contains(declinedId.uuidString) },
			"A declined finding must never be uploaded by a later, opposite answer: \(uploaded)"
		)
	}

}
