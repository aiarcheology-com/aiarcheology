//
//  ModelTypeBackfillerTests.swift
//  AI ArcheologyTests
//
//  AIA-0402: one-time re-derivation of `modelTypeParsed` for rows that predate the attribute.
//

import XCTest
import CoreData
@testable import ML_Browser

@MainActor
final class ModelTypeBackfillerTests: XCTestCase {

    private var dataController: DataController!
    private var context: NSManagedObjectContext!
    private var defaults: UserDefaults!
    private let suiteName = "com.aiarcheology.tests.modeltypebackfiller"

    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        context = dataController.container.viewContext
        // Isolated defaults so the one-shot guard never bleeds across tests or into `.standard`.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        context = nil
        dataController = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Seeds a minimally-valid (draft) row; `demo`/`file_` control whether `config.file` resolves.
    @discardableResult
    private func seed(demo: Bool, fileName: String?, typeString: String, parsed: Bool) -> DeepConfiguration {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.demo = demo
        config.file_ = fileName.flatMap { URL(string: $0) }
        config.modelTypeString = typeString
        config.modelTypeParsed = parsed
        config.phaseOutTime = 0.5
        config.annotationColor = .red
        config.lifeCycle = .draft
        return config
    }

    private func backfiller() -> ModelTypeBackfiller {
        ModelTypeBackfiller(dataController: dataController, defaults: defaults)
    }

    private func aiArcheologyIsBundled() -> Bool {
        Bundle.main.url(forResource: DemoDataManager.DemoModelResource.aiArcheology, withExtension: "mlmodelc") != nil
    }

    // MARK: - Tests

    /// A declared-type demo detector left `false` by migration is re-parsed, locked, and its stored
    /// type set to the authoritative parser value.
    func test_backfill_locksParserDecidedModel() async throws {
        try XCTSkipUnless(aiArcheologyIsBundled(), "AIArcheology demo model not in test bundle")

        // Stored as classify to prove the backfill also corrects a stale type to what the file declares.
        let config = seed(demo: true, fileName: "AIArcheology.mlmodelc", typeString: "classify", parsed: false)

        await backfiller().backfillIfNeeded()

        XCTAssertTrue(config.modelTypeParsed, "A parser-decided model must be locked after backfill")
        XCTAssertEqual(config.modelType, .detector, "The stored type must be corrected to the declared value")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The one-shot guard must be set")
    }

    /// Once the guard flag is set, a later launch does not re-touch rows (no re-parse).
    func test_backfill_guardPreventsRerun() async {
        defaults.set(true, forKey: ModelTypeBackfiller.defaultsKey)
        let config = seed(demo: true, fileName: "AIArcheology.mlmodelc", typeString: "detect", parsed: false)

        await backfiller().backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "The guard must short-circuit before any re-derivation")
    }

    /// A row whose file can't be resolved stays user-owned (editable); the guard still advances so
    /// the (pointless) re-parse isn't retried forever.
    func test_backfill_skipsUnresolvableFileButSetsGuard() async {
        let config = seed(demo: false, fileName: nil, typeString: "detect", parsed: false)

        await backfiller().backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "An unresolvable file must leave the row user-owned")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The guard must still be set")
    }

    /// A fresh install has no `false` rows to migrate; the backfill is a no-op that just arms the guard.
    func test_backfill_noPendingRows_setsGuardOnly() async {
        let alreadyLocked = seed(demo: true, fileName: "AIArcheology.mlmodelc", typeString: "detect", parsed: true)

        await backfiller().backfillIfNeeded()

        XCTAssertTrue(alreadyLocked.modelTypeParsed, "An already-locked row must be left untouched")
        XCTAssertEqual(alreadyLocked.modelType, .detector)
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The guard must be set")
    }
}
