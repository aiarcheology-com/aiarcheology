//
//  BrowsingHistoryRefreshTests.swift
//  MLBrowserUnitTests
//
//  AIA-0307: regression lock for the Browsing History list refreshing after a per-row delete
//  and after clear-all.
//
//  Assertions operate on a live `NSFetchedResultsController` bound to the viewContext — the
//  exact mechanism `@FetchRequest` uses — NOT on a fresh post-delete fetch. A fresh fetch always
//  hits the (now-empty) store and returns 0 regardless of whether the in-memory merge reached the
//  viewContext, which would false-pass. The FRC only drops rows when the delete actually
//  propagates to the context backing the list, so it tests the real refresh behavior.
//
//  Uses a temporary SQLite store: `NSBatchDeleteRequest` (clear-all) does not work with
//  `NSInMemoryStoreType` (AGENTS.md §6).
//

import CoreData
import XCTest
@testable import ML_Browser

@MainActor
final class BrowsingHistoryRefreshTests: XCTestCase {

    /// Fires `onChange` whenever the observed FRC's content updates, so tests can wait on the
    /// refresh deterministically instead of sleeping.
    private final class FRCChangeSpy: NSObject, NSFetchedResultsControllerDelegate {
        var onChange: (() -> Void)?
        func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
            onChange?()
        }
    }

    private var storeURL: URL!
    private var controller: DataController!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRefreshTest-\(UUID().uuidString).sqlite")
        controller = DataController(storeURL: storeURL)
        // SQLite stores load synchronously (shouldAddStoreAsynchronously defaults false), but await
        // readiness explicitly so the stack is deterministically ready before any fetch/save.
        await controller.awaitStoreReady()
    }

    override func tearDown() async throws {
        controller = nil
        if let url = storeURL {
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
        storeURL = nil
        try await super.tearDown()
    }

    private var viewContext: NSManagedObjectContext { controller.container.viewContext }

    /// An FRC matching `BrowserHistoryView`'s `@FetchRequest` (same predicate + sort), already
    /// fetched and ready to observe context changes.
    private func makeHistoryFRC() throws -> NSFetchedResultsController<WebHistoryEntry> {
        let request = WebHistoryEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)]
        request.predicate = NSPredicate(format: "lifeCycleString == %@ AND page != nil AND creationDate_ != nil", "ready")
        let frc = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        try frc.performFetch()
        return frc
    }

    @discardableResult
    private func seedReadyEntries(_ count: Int) throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            let entry = WebHistoryEntry(context: viewContext)
            let id = UUID()
            entry.entityId = id
            entry.page = URL(string: "https://example.com/\(index)")
            entry.creationDate_ = Date(timeIntervalSince1970: TimeInterval(1000 + index))
            entry.lifeCycle = .ready
            ids.append(id)
        }
        try viewContext.save()
        return ids
    }

    func testClearAll_dropsAllRowsFromFetchedResultsController() throws {
        try seedReadyEntries(5)
        let frc = try makeHistoryFRC()
        XCTAssertEqual(frc.fetchedObjects?.count, 5, "FRC should report the seeded rows before clear-all")

        let spy = FRCChangeSpy()
        frc.delegate = spy
        let changed = expectation(description: "FRC content changed after clear-all")
        changed.assertForOverFulfill = false
        spy.onChange = { changed.fulfill() }

        try WebHistoryEntry.deleteAll(in: viewContext)

        wait(for: [changed], timeout: 5)
        XCTAssertEqual(frc.fetchedObjects?.count, 0, "Clear-all must empty the list the FRC drives")
    }

    func testDeleteEntry_dropsOneRowFromFetchedResultsController() throws {
        let ids = try seedReadyEntries(5)
        let frc = try makeHistoryFRC()
        XCTAssertEqual(frc.fetchedObjects?.count, 5, "FRC should report the seeded rows before delete")

        let spy = FRCChangeSpy()
        frc.delegate = spy
        let changed = expectation(description: "FRC content changed after per-row delete")
        changed.assertForOverFulfill = false
        spy.onChange = { changed.fulfill() }

        WebHistoryEntry.delete(ids[0], in: viewContext)

        wait(for: [changed], timeout: 5)
        XCTAssertEqual(frc.fetchedObjects?.count, 4, "A per-row delete must remove exactly that row from the list")
    }

    // Faithful to the app: the demo history is created on a BACKGROUND context and saved to the
    // store; the History screen's `@FetchRequest` then fetches those rows fresh into the
    // viewContext. This exercises the per-row delete on objects that originated on another context
    // and were realized via a store fetch — the exact data path behind the screen.
    func testDeleteEntry_onRowsFetchedFreshFromStore_dropsRow() throws {
        let backgroundContext = controller.container.newBackgroundContext()
        let firstId: UUID = try backgroundContext.performAndWait {
            var ids: [UUID] = []
            for index in 0..<6 {
                let entry = WebHistoryEntry(context: backgroundContext)
                entry.entityId = UUID()
                entry.page = URL(string: "https://example.com/\(index)")
                entry.creationDate_ = Date(timeIntervalSince1970: TimeInterval(1000 + index))
                entry.lifeCycle = .ready
                ids.append(entry.entityId)
            }
            try backgroundContext.save()
            return ids[0]
        }

        // performFetch reads the background-saved rows straight from the store — race-free.
        let frc = try makeHistoryFRC()
        XCTAssertEqual(frc.fetchedObjects?.count, 6, "All six store-seeded rows should be fetched")

        let spy = FRCChangeSpy()
        frc.delegate = spy
        let changed = expectation(description: "FRC content changed after per-row delete")
        changed.assertForOverFulfill = false
        spy.onChange = { changed.fulfill() }

        WebHistoryEntry.delete(firstId, in: viewContext)

        // The delete persists immediately on the viewContext...
        XCTAssertEqual(WebHistoryEntry.count(in: viewContext), 5, "Per-row delete must remove the row from the store")
        // ...and the FRC reflects it once it gets a run-loop turn to process the change (as SwiftUI's
        // @FetchRequest does). A synchronous read right after delete would still show the stale count.
        wait(for: [changed], timeout: 5)
        XCTAssertEqual(frc.fetchedObjects?.count, 5, "FRC must reflect the per-row delete of a store-fetched row")
    }

    // Vacuity / non-vacuous guard: a batch delete that hits the store but is NOT merged into the
    // viewContext leaves the FRC count unchanged. This proves the count-drop asserted above comes
    // from the merge reaching the context — not from the FRC silently re-fetching an emptied store.
    func testBatchDeleteWithoutMerge_leavesFetchedResultsControllerUnchanged() throws {
        try seedReadyEntries(5)
        let frc = try makeHistoryFRC()
        XCTAssertEqual(frc.fetchedObjects?.count, 5)

        try viewContext.performAndWait {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = WebHistoryEntry.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            deleteRequest.resultType = .resultTypeObjectIDs
            // Deliberately NOT calling mergeChanges(fromRemoteContextSave:into:) — the store rows
            // are gone, but the viewContext is never notified.
            _ = try viewContext.execute(deleteRequest)
        }

        XCTAssertEqual(
            frc.fetchedObjects?.count, 5,
            "Without the merge the FRC must NOT change — confirms the real tests' drop is merge-driven, not a store re-fetch"
        )
    }
}
