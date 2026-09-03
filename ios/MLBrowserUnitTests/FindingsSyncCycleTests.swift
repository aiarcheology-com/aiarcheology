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
			metadata: FindingMetadata(title: title, label: "", note: "", author: "", gps: "", page: nil)
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

	// MARK: - Synchronize (AIA-0758)

	/// The whole point of splitting the button: a neutral action must not reverse a decision the
	/// user recorded per finding.
	///
	/// Mutation check for whoever changes this later: point the call below at `backUpNow` instead
	/// and this test MUST fail. If it still passes, it is asserting nothing.
	func testSynchronizeDoesNotLiftKeepOnThisDeviceExclusions() async throws {
		// Belonging to nobody, so the card is actually raised: a finding created while signed in is
		// `owned` at birth and is never the subject of a consent question.
		let strangerId = try saveFindingBelongingToNobody(title: "Somebody else's ditch").entityId
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": UUID().uuidString, "modifiedAt": 1, "receivedAt": 2,
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

		// Reach the same state AIA-740 is about: the card asked, and the user said keep it here.
		await sut.syncNow()?.value
		await sut.answerBackupConsent(accepted: false)?.value

		StubWorkerProtocol.requests = []
		await sut.synchronizeNow(expectedAccount: try XCTUnwrap(auth.accountIdentifier))?.value

		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") && $0.contains(strangerId.uuidString) } == false,
			"Synchronize must not upload a finding the user chose to keep on this device: "
				+ "\(StubWorkerProtocol.requests)"
		)

		// The exclusion must still be on disk, not merely unused by that one cycle: a synchronize
		// that silently emptied `excluded` would pass the check above and upload on the next
		// ordinary trigger instead.
		StubWorkerProtocol.requests = []
		await sut.syncNow()?.value
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") && $0.contains(strangerId.uuidString) } == false,
			"the exclusion must survive the synchronize, not just be skipped by it: "
				+ "\(StubWorkerProtocol.requests)"
		)
	}

	/// `backUpNow` forces back-up on; Synchronize deliberately does not. A neutral label may not
	/// flip a switch the user set.
	func testSynchronizeLeavesTheBackUpSwitchAlone() async throws {
		try saveFinding(title: "Stays here")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)
		await sut.setBackUpEnabled(false, expectedAccount: account)?.value
		XCTAssertFalse(sut.isBackUpEnabled)

		StubWorkerProtocol.requests = []
		await sut.synchronizeNow(expectedAccount: account)?.value

		XCTAssertFalse(sut.isBackUpEnabled, "Synchronize must not turn back-up back on")
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") } == false,
			"back-up is off, so nothing may leave the device: \(StubWorkerProtocol.requests)"
		)
		// And the report must not claim otherwise. With back-up off nothing was pushed, so any
		// wording about findings being backed up would be false -- `.succeeded` here means only
		// that the cycle finished, and the pending count says what is still owed.
		XCTAssertEqual(sut.lastSynchronize, .succeeded)
		XCTAssertNil(sut.lastManualBackup, "a synchronize must not present itself as a back-up")
	}

	/// An unanswered "whose findings are these?" card must survive a neutral action. `backUpNow`
	/// clears it because pressing that button IS the answer; Synchronize is not.
	func testSynchronizeDoesNotDismissAnUnansweredConsentPrompt() async throws {
		try saveFindingBelongingToNobody(title: "Whose is this?")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertNotNil(sut.backupConsentRequest, "precondition: the card is up")

		StubWorkerProtocol.requests = []
		await sut.synchronizeNow(expectedAccount: try XCTUnwrap(auth.accountIdentifier))?.value

		XCTAssertNotNil(
			sut.backupConsentRequest,
			"Synchronize must not answer the consent question by dismissing it"
		)
		// Be honest about the limit of the line above: `push` re-raises the card for a finding that
		// is still unclaimed, so it cannot tell a transient dismissal from no dismissal at all.
		// What it *does* catch, and what actually matters, is the variant that answers the question
		// by claiming the finding -- so assert the durable half directly: still not uploaded.
		XCTAssertTrue(
			StubWorkerProtocol.requests.contains { $0.hasPrefix("PUT") } == false,
			"a finding nobody has claimed must not be uploaded by a neutral action: "
				+ "\(StubWorkerProtocol.requests)"
		)
	}

	/// The AIA-740 fence, on the new path too: the account the user was looking at travels with the
	/// request and is checked against the provider rather than trusted.
	func testSynchronizeRefusesWhenTheAccountHasMovedOn() async throws {
		try saveFinding(title: "Not yours")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		StubWorkerProtocol.requests = []
		XCTAssertNil(
			sut.synchronizeNow(expectedAccount: "user_somebody_else"),
			"a press made under one account must not run under another"
		)
		XCTAssertFalse(sut.isBackingUp, "a refused request must not leave the button spinning")
		// A nil return is not by itself proof: the refusal has to happen before anything is asked
		// of the Worker, or the request went out under the wrong credential regardless.
		XCTAssertTrue(
			StubWorkerProtocol.requests.isEmpty,
			"a refused press must not have talked to the Worker at all: \(StubWorkerProtocol.requests)"
		)
	}

	/// A finding parked permanently (`payload_too_large`) is standing status, not the result of the
	/// cycle the user just asked for. Reporting it as a failure would also send the same permanent
	/// condition to Sentry on every press.
	func testSynchronizeReportsSuccessDespiteAnOlderPermanentPark() async throws {
		try saveFinding(title: "Too big")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "PUT" {
				return (413, StubWorkerProtocol.json([
					"error": ["code": "payload_too_large", "message": "too big", "retryable": false]
				]))
			}
			return (200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}
		let account = try XCTUnwrap(auth.accountIdentifier)
		// Park it through the explicit path, which is what reports parked work as a failure.
		await sut.backUpNow(expectedAccount: account)?.value
		XCTAssertEqual(sut.lastManualBackup, .failed, "precondition: the back-up path does report it")
		XCTAssertTrue(sut.parkedCount > 0)

		await sut.synchronizeNow(expectedAccount: account)?.value

		XCTAssertEqual(
			sut.lastSynchronize, .succeeded,
			"a standing park is status above the list, not the outcome of this cycle"
		)
		XCTAssertNil(sut.lastManualBackup, "starting a synchronize clears the older back-up outcome")
	}

	/// AIA-0758: `syncNow()` hands back the cycle already running and used to schedule the follow-up
	/// fire-and-forget. Awaiting the returned task therefore returned while the cycle that could
	/// actually see the caller's change had not started -- pull-to-refresh stopped spinning early,
	/// and a pressed button reported success on work that predated the press.
	func testAwaitingSyncNowWaitsForTheCycleQueuedWhileOneWasRunning() async throws {
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		// Measure what one cycle costs, so the assertion below is about the SECOND cycle existing
		// rather than about a hard-coded request count that a change to the pull would invalidate.
		await sut.syncNow()?.value
		let requestsPerCycle = StubWorkerProtocol.requests.count
		XCTAssertGreaterThan(requestsPerCycle, 0, "precondition: a cycle talks to the Worker")

		StubWorkerProtocol.requests = []
		// Both calls happen before this actor yields, so the second one lands while the first cycle
		// is still in flight -- the coalescing path, which is the one that was broken.
		let first = try XCTUnwrap(sut.syncNow())
		let second = try XCTUnwrap(sut.syncNow())
		XCTAssertEqual(first, second, "precondition: the second trigger coalesces onto the first")

		await second.value

		// Before the fix the follow-up cycle was started with `_ = self?.syncNow()` and nobody
		// awaited it, so this returned after ONE cycle's worth of requests -- i.e. after a cycle
		// that had already read the store before the second trigger existed.
		XCTAssertGreaterThanOrEqual(
			StubWorkerProtocol.requests.count, requestsPerCycle * 2,
			"awaiting the returned task must await the cycle the second trigger asked for: "
				+ "\(StubWorkerProtocol.requests)"
		)
	}

	// MARK: - Per-finding back-up state (AIA-0735)

	/// The projection itself, against a hand-built ledger. Pure and deterministic: no network, no
	/// cycle, so a failure here is the derivation and nothing else.
	func testEachFindingGetsTheStateItsLedgerEntryImplies() throws {
		let backedUp = try saveFinding(title: "Safe in the cloud")
		let stale = try saveFinding(title: "Edited since it went up")
		let excluded = try saveFinding(title: "Kept here on purpose")
		let unclaimed = try saveFinding(title: "Never answered for")

		var ledger = FindingsSyncLedger()
		ledger.owned = [backedUp.entityId.uuidString, stale.entityId.uuidString]
		// The cloud holds both at timestamp 1000.
		ledger.uploaded = [
			backedUp.entityId.uuidString: 1_000,
			stale.entityId.uuidString: 1_000
		]
		ledger.excluded = [excluded.entityId.uuidString]

		// `stale` has been edited since: its local clock is ahead of what the cloud confirmed.
		let localTimes: [UUID: Int64] = [
			backedUp.entityId: 1_000,
			stale.entityId: 2_000,
			excluded.entityId: 500,
			unclaimed.entityId: 500
		]

		let states = FindingsSyncCoordinator.backupStates(
			for: [backedUp, stale, excluded, unclaimed],
			ledger: ledger
		) { localTimes[$0.entityId] ?? 0 }

		XCTAssertEqual(states[backedUp.entityId], .backedUp)
		XCTAssertEqual(states[stale.entityId], .owed, "an edit since the upload is owed again")
		XCTAssertEqual(
			states[excluded.entityId], .keptOnDevice,
			"a deliberate choice must not be reported as merely waiting -- nothing will change it"
		)
		XCTAssertEqual(
			states[unclaimed.entityId], .owed,
			"never claimed is still not in the cloud, whatever the reason"
		)
	}

	/// Exclusion is checked before "needs upload", and both are true for the same finding. Getting
	/// the order wrong shows a kept-on-device finding as a queue that will drain, which it will not.
	func testKeptOnDeviceWinsOverOwed() throws {
		let finding = try saveFinding(title: "Both at once")
		var ledger = FindingsSyncLedger()
		ledger.excluded = [finding.entityId.uuidString]

		let states = FindingsSyncCoordinator.backupStates(for: [finding], ledger: ledger) { _ in 1_000 }

		XCTAssertEqual(states[finding.entityId], .keptOnDevice)
	}

	/// Signed out renders no icon at all, which is what an empty projection produces.
	func testSigningOutClearsEveryRowIcon() async throws {
		try saveFinding(title: "Mine")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		XCTAssertFalse(sut.backupStates.isEmpty, "precondition: a signed-in cycle produced states")

		auth.setOutcomeForTesting(.signedOut)
		await sut.syncNow()?.value

		XCTAssertTrue(
			sut.backupStates.isEmpty,
			"a signed-out person is not owed a report on somebody's cloud"
		)
	}

	/// The one this projection is most likely to get wrong. Signing out clears the states, but
	/// signing straight from one account into another never passes through that branch -- so without
	/// an explicit account-change clear, B's findings would wear A's ticks.
	func testSwitchingAccountDirectlyDoesNotLeaveTheOtherAccountsIcons() async throws {
		// `keptOnDevice` is the state to test the switch with, because it is the one that CANNOT
		// arise by accident under the second account: it is recorded only by answering A's consent
		// card, and B's ledger is empty. Comparing "backed up" against "owed" would not do -- the
		// stub confirms an upload at its own timestamp while the local clock is far ahead, so a
		// finding reads as owed under both accounts and the assertion would pass vacuously.
		let shared = try saveFindingBelongingToNobody(title: "Shared device")
		StubWorkerProtocol.handler = { _ in
			(200, StubWorkerProtocol.json([
				"findings": [], "nextCursor": NSNull(), "hasMore": false,
				"usage": ["used": 0, "limit": 52_428_800]
			]))
		}

		await sut.syncNow()?.value
		await sut.answerBackupConsent(accepted: false)?.value
		await sut.syncNow()?.value
		XCTAssertEqual(
			sut.backupStates[shared.entityId], .keptOnDevice,
			"precondition: account A recorded a decision about this finding"
		)

		// Straight from A to B. No sign-out in between: the nil-account branch of `cycle()` never
		// runs, so if anything carried A's decision across, this is where it would show.
		auth.setAccountIDForTesting("user_somebody_entirely_else")
		await sut.syncNow()?.value

		XCTAssertEqual(
			sut.backupStates[shared.entityId], .owed,
			"account B must not inherit account A's decision -- the ledger is per account, and this "
				+ "icon is a claim about one person's cloud"
		)

		// **What this test does and does not pin.** It pins the user-visible property: B never sees
		// A's `keptOnDevice`. It does NOT prove the explicit account-change clear in `cycle()`,
		// because a cycle that reaches its end rebuilds the whole map from B's ledger anyway --
		// `refreshCounts` runs even after a *caught* transport error, so a failing cycle does not
		// separate the two either. The clear earns its place on the paths that exit before the
		// rebuild (cancellation, a sign-out mid-cycle), and those cannot be provoked deterministically
		// from here. `testPurgingCloudDataClearsEveryRowIcon` is the one that pins a clear with no
		// rebuild behind it; that is where the mutation dies.
	}

	/// A permanent refusal must never read as backed up.
	///
	/// `needsUpload` is false for a parked finding -- retrying cannot cure what was refused -- so a
	/// derivation that reads that as "nothing owed" falls through to the upload receipt and turns
	/// the row green at the exact moment the user's edit was lost. The cloud still holds the copy
	/// from before the edit.
	func testAnEditRefusedForGoodDoesNotReadAsBackedUp() throws {
		let finding = try saveFinding(title: "Edited, then refused")
		var ledger = FindingsSyncLedger()
		ledger.owned = [finding.entityId.uuidString]
		// The cloud confirmed the PRE-edit copy.
		ledger.uploaded = [finding.entityId.uuidString: 1_000]
		// The edit was refused permanently, and the park records the timestamp that was refused.
		ledger.parked = [finding.entityId.uuidString: ParkedUpload(code: "payload_too_large", modifiedAt: 2_000)]

		let states = FindingsSyncCoordinator.backupStates(for: [finding], ledger: ledger) { _ in 2_000 }

		XCTAssertEqual(
			states[finding.entityId], .owed,
			"the cloud holds the copy from before the edit, so this finding is not backed up"
		)
	}

	/// The other half: a finding that was never in the cloud and has been parked is still owed, not
	/// silently absent from the projection.
	func testAFindingParkedBeforeItEverUploadedIsOwed() throws {
		let finding = try saveFinding(title: "Too big from the start")
		var ledger = FindingsSyncLedger()
		ledger.owned = [finding.entityId.uuidString]
		ledger.parked = [finding.entityId.uuidString: ParkedUpload(code: "payload_too_large", modifiedAt: 2_000)]

		let states = FindingsSyncCoordinator.backupStates(for: [finding], ledger: ledger) { _ in 2_000 }

		XCTAssertEqual(states[finding.entityId], .owed)
	}

	/// Purging the account's cloud data must take every row mark with it. It is the third place this
	/// has to happen and the worst one to miss: the cloud copies are gone, the account is about to
	/// be deleted, and the cycle that would rebuild the projection has been cancelled.
	func testPurgingCloudDataClearsEveryRowIcon() async throws {
		try saveFinding(title: "About to be erased")
		StubWorkerProtocol.handler = { request in
			if request.httpMethod == "DELETE" {
				return (200, StubWorkerProtocol.json(["purged": ["complete": true, "objects": 1]]))
			}
			if request.httpMethod == "PUT" {
				return (200, StubWorkerProtocol.json([
					"finding": [
						"id": UUID().uuidString, "modifiedAt": 1, "receivedAt": 2,
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

		await sut.syncNow()?.value
		XCTAssertFalse(sut.backupStates.isEmpty, "precondition: the rows have marks to lose")

		try await sut.purgeCloudData(operation: "test")

		XCTAssertTrue(
			sut.backupStates.isEmpty,
			"a tick claiming these findings are safe in an account that no longer exists"
		)
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
