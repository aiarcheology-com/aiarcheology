//
//  VisitTrailRecorderTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import XCTest
import CoreData
@testable import ML_Browser

@MainActor
final class VisitTrailRecorderTests: XCTestCase {

    var settings: Settings!
    var dataController: DataController!
    var browserState: BrowserState!
    var sut: VisitTrailRecorder!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        dataController = DataController(inMemory: true)
        await dataController.awaitStoreReady()
        browserState = BrowserState(settings: settings)
        sut = VisitTrailRecorder(browserState: browserState, dataController: dataController)
    }

    override func tearDown() async throws {
        sut = nil
        browserState = nil
        dataController = nil
        settings = nil
        try await super.tearDown()
    }

    /// Polls until the visit count reaches the expectation — the recorder persists on a
    /// background context, merged asynchronously into the view context.
    private func waitForVisitCount(_ expected: Int, timeout: TimeInterval = 5) async -> Int {
        let context = dataController.container.viewContext
        let deadline = Date().addingTimeInterval(timeout)
        var count = WebVisit.count(in: context)
        while count != expected && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            count = WebVisit.count(in: context)
        }
        return count
    }

    func testRecord_PersistsVisitWithHostAndTimestamp() async {
        let url = URL(string: "https://maps.example.com/view?x=10&y=20")!

        sut.record(url)

        let count = await waitForVisitCount(1)
        XCTAssertEqual(count, 1)
        let visit = WebVisit.selectAll(in: dataController.container.viewContext).first
        XCTAssertEqual(visit?.page, url)
        XCTAssertEqual(visit?.host, "maps.example.com")
        XCTAssertNotNil(visit?.creationDate_)
        XCTAssertEqual(visit?.lifeCycle, .ready)
    }

    func testRecord_KeepsSeparateEntriesPerURL() async {
        sut.record(URL(string: "https://maps.example.com/view?x=1")!)
        sut.record(URL(string: "https://maps.example.com/view?x=2")!)

        let count = await waitForVisitCount(2)

        XCTAssertEqual(count, 2, "Each settled URL is one trail step")
    }

    func testPrune_CapsTheTrailAtMaxVisits_OldestFirst() async {
        let context = dataController.container.viewContext
        let overflow = 5
        for index in 0..<(VisitTrailRecorder.maxVisits + overflow) {
            let visit: WebVisit = WebVisit.create(in: context)
            // Strictly increasing timestamps so "oldest" is deterministic.
            visit.creationDate_ = Date(timeIntervalSince1970: TimeInterval(index))
            visit.page = URL(string: "https://maps.example.com/view?x=\(index)")
            visit.host = "maps.example.com"
            visit.transition(to: .draft)
            visit.transition(to: .ready)
        }
        try? WebVisit.save(in: context)

        VisitTrailRecorder.prune(in: context)

        XCTAssertEqual(WebVisit.count(in: context), VisitTrailRecorder.maxVisits)
        // The oldest entries (smallest timestamps) must be the ones removed.
        let request = WebVisit.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WebVisit.creationDate_, ascending: true)]
        request.fetchLimit = 1
        let oldest = try? context.fetch(request).first
        XCTAssertEqual(oldest?.creationDate_, Date(timeIntervalSince1970: TimeInterval(overflow)))
    }
}
