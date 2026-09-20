import XCTest
@testable import ProjectToolCore

final class XcodeCloudTests: XCTestCase {
    private let buildID = "625a8b0a-f83a-43d9-92c2-892924582840"
    private let actionID = "3e5984a0-f4bb-4186-b85a-7b3f81607c1e"
    private let productID = "dab07d52-e272-4541-b291-2a4d581a5ef5"
    private let api = "https://api.appstoreconnect.apple.com/v1/"

    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func page(_ rows: [[String: Any]], next: String? = nil, included: [[String: Any]] = []) -> [String: Any] {
        ["data": rows, "included": included, "links": ["next": next as Any? ?? NSNull()]]
    }
    private func buildRun(number: Int = 1, date: String = "2026-09-20T18:14:22.656Z", ref: String = "branch",
                     pr: Bool = false, progress: String = "RUNNING", status: String? = nil) -> [String: Any] {
        ["id": buildID, "attributes": ["number": number, "createdDate": date, "isPullRequestBuild": pr,
          "executionProgress": progress, "completionStatus": status as Any? ?? NSNull()],
         "relationships": ["sourceBranchOrTag": ["data": ["id": ref]]]]
    }

    func testBuildUUIDAndFullActionURLSelectTheSameBuild() throws {
        let url = "https://appstoreconnect.apple.com/teams/8860a21d-753a-4c72-8d14-bd217562ae26/xcode-cloud/products/\(productID)/builds/\(buildID)/action/\(actionID)/issues"
        XCTAssertEqual(try XcodeCloudClient.buildID(from: url), buildID)
        XCTAssertEqual(try XcodeCloudClient.buildID(from: buildID.uppercased()), buildID.uppercased())
        for invalid in ["1110", "https://evil.example/builds/\(buildID)", "http://appstoreconnect.apple.com/builds/\(buildID)",
                        "https://appstoreconnect.apple.com/builds/\(buildID)", "../\(buildID)"] {
            XCTAssertThrowsError(try XcodeCloudClient.buildID(from: invalid))
        }
    }

    func testTokenDestinationValidationRejectsForeignOriginsAndCredentials() throws {
        XCTAssertEqual(try XcodeCloudClient.identifier(productID.uppercased()), productID.uppercased())
        for invalid in ["http://api.appstoreconnect.apple.com/v1/apps", "https://api.appstoreconnect.apple.com.evil.example/v1/apps",
                        "https://user@api.appstoreconnect.apple.com/v1/apps", "https://api.appstoreconnect.apple.com:8443/v1/apps",
                        "https://api.appstoreconnect.apple.com/v1/apps#fragment", "https://api.appstoreconnect.apple.com/other"] {
            XCTAssertThrowsError(try XcodeCloudClient.apiURL(invalid))
        }
        XCTAssertNoThrow(try XcodeCloudClient.apiURL(api + "ciBuildRuns?cursor=next"))
    }

    func testLatestBranchBuildSearchesAllPagesAndExcludesPRsAndTags() async throws {
        let next = api + "ciProducts/\(productID)/buildRuns?cursor=2"
        var old = buildRun(number: 100, date: "2026-09-19T18:14:22Z")
        old["id"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let reference: [String: Any] = ["id": "branch", "attributes": ["name": "release/1.0.9", "kind": "BRANCH"]]
        let tag: [String: Any] = ["id": "tag", "attributes": ["name": "release/1.0.9", "kind": "TAG"]]
        var calls = 0
        let client = XcodeCloudClient { url in
            calls += 1
            if url.absoluteString == next {
                var pullRequest = self.buildRun(number: 103, date: "2026-09-21T18:00:00Z", pr: true)
                pullRequest["id"] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                var tagged = self.buildRun(number: 104, date: "2026-09-22T18:00:00Z", ref: "tag")
                tagged["id"] = "cccccccc-cccc-cccc-cccc-cccccccccccc"
                return try self.data(self.page([
                    self.buildRun(number: 101),
                    pullRequest,
                    tagged
                ], included: [tag]))
            }
            return try self.data(self.page([old], next: next, included: [reference]))
        }
        let selected = try await client.latestBuild(branch: "release/1.0.9", product: productID)
        XCTAssertEqual(selected, buildID)
        XCTAssertEqual(calls, 2)
    }

    func testMissingExactBranchFailsInsteadOfWatchingAnotherBranch() async throws {
        let client = XcodeCloudClient { _ in
            try self.data(self.page([self.buildRun()], included: [["id": "branch", "attributes": ["name": "develop-old", "kind": "BRANCH"]]]))
        }
        do {
            _ = try await client.latestBuild(branch: "develop", product: productID)
            XCTFail("A prefix match must not select develop-old")
        } catch { XCTAssertTrue(String(describing: error).contains("No non-PR")) }
    }

    func testForeignPaginationIsRejectedBeforeTheTransportReceivesIt() async throws {
        var calls = 0
        let client = XcodeCloudClient { _ in
            calls += 1
            return try self.data(self.page([], next: "https://evil.example/steal-token"))
        }
        do {
            _ = try await client.latestBuild(branch: "develop", product: productID)
            XCTFail("Unexpected pagination origin accepted")
        } catch { XCTAssertEqual(calls, 1) }
    }

    func testPaginationCycleFailsRatherThanHanging() async throws {
        var calls = 0
        let client = XcodeCloudClient { url in
            calls += 1
            return try self.data(self.page([], next: url.absoluteString))
        }
        do {
            _ = try await client.latestBuild(branch: "develop", product: productID)
            XCTFail("Cyclic pagination accepted")
        } catch { XCTAssertEqual(calls, 1) }
    }

    func testSnapshotDiscoversActionsAndIncludesFailuresOnLaterResultPages() async throws {
        let next = api + "ciBuildActions/\(actionID)/testResults?cursor=2"
        var testRequests = 0
        let client = XcodeCloudClient { url in
            if url.path.hasSuffix("/\(self.buildID)") {
                return try self.data(["data": self.buildRun(progress: "COMPLETE", status: "FAILED")])
            }
            if url.path.hasSuffix("/actions") {
                return try self.data(self.page([["id": self.actionID, "attributes": [
                    "name": "Dynamically discovered action", "actionType": "TEST",
                    "executionProgress": "COMPLETE", "completionStatus": "FAILED"]]]))
            }
            if url.path.hasSuffix("/issues") {
                return try self.data(self.page([["id": "issue", "attributes": ["issueType": "WARNING", "message": "Warning\u{1b}[31m"]]]))
            }
            testRequests += 1
            if url.absoluteString == next {
                return try self.data(self.page([["id": "second", "attributes": ["status": "FAILURE", "name": "testFails", "className": "Suite", "message": "Assertion failed"]]]))
            }
            return try self.data(self.page([["id": "first", "attributes": ["status": "SUCCESS", "name": "testPasses"]]], next: next))
        }
        let snapshot = try await client.snapshot(buildID: buildID)
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertFalse(snapshot.succeeded)
        XCTAssertEqual(snapshot.actions.first?.tests?.count, 2)
        XCTAssertTrue(snapshot.report().contains("FAILURE: Suite.testFails"))
        XCTAssertFalse(snapshot.report().contains("\u{1b}"))
        _ = try await client.snapshot(buildID: buildID)
        XCTAssertEqual(testRequests, 2, "Completed results are reused while other actions are still running")
    }

    func testEveryUnsuccessfulTerminalStatusRemainsUnsuccessful() throws {
        for status in ["FAILED", "ERRORED", "CANCELED", "SKIPPED", "FUTURE_STATUS", nil] {
            let resource = try JSONDecoder().decode(CloudResource<CloudRun>.self, from: data(buildRun(progress: "COMPLETE", status: status)))
            let snapshot = CloudSnapshot(run: resource, actions: [])
            XCTAssertTrue(snapshot.isComplete)
            XCTAssertFalse(snapshot.succeeded)
        }
        let resource = try JSONDecoder().decode(CloudResource<CloudRun>.self, from: data(buildRun(progress: "COMPLETE", status: "SUCCEEDED")))
        XCTAssertTrue(CloudSnapshot(run: resource, actions: []).succeeded)
    }

    func testRunningSnapshotDoesNotFetchOrClaimTestPasses() async throws {
        let client = XcodeCloudClient { url in
            if url.path.hasSuffix("/\(self.buildID)") { return try self.data(["data": self.buildRun()]) }
            if url.path.hasSuffix("/actions") {
                return try self.data(self.page([["id": self.actionID, "attributes": [
                    "name": "Tests", "actionType": "TEST", "executionProgress": "RUNNING"]]]))
            }
            XCTAssertTrue(url.path.hasSuffix("/issues"), "No test result request before action completion")
            return try self.data(self.page([]))
        }
        let snapshot = try await client.snapshot(buildID: buildID)
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertFalse(snapshot.succeeded)
        XCTAssertNil(snapshot.actions.first?.tests)
        XCTAssertTrue(snapshot.report().contains("Test totals pending"))
    }
}
