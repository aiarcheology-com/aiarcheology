//
//  ModelTypeBackfillerTests.swift
//  AI ArcheologyTests
//
//  AIA-0402/AIA-0478: one-time backfills for metadata fields that predate persistence.
//

import XCTest
import CoreData
@testable import ML_Browser

private actor StubModelMetadataLoader: ModelMetadataLoading {
    private let result: ExtractedModelInfo
    private var callCount = 0

    init(result: ExtractedModelInfo) {
        self.result = result
    }

    func loadAndExtractMetadata(from url: URL, demo: Bool) async throws -> ExtractedModelInfo {
        callCount += 1
        return result
    }

    func calls() -> Int {
        callCount
    }
}

private actor FailingModelMetadataLoader: ModelMetadataLoading {
    func loadAndExtractMetadata(from url: URL, demo: Bool) async throws -> ExtractedModelInfo {
        throw ModelLoadingError.modelLoadFailed(url)
    }
}

@MainActor
final class ModelTypeBackfillerTests: XCTestCase {

    private var dataController: DataController!
    private var context: NSManagedObjectContext!
    private var defaults: UserDefaults!
    private let suiteName = "com.aiarcheology.tests.modeltypebackfiller"

    override func setUp() async throws {
        try await super.setUp()
        dataController = DataController(inMemory: true)
        await dataController.awaitStoreReady()
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
    private func seed(
        demo: Bool,
        fileName: String?,
        typeString: String,
        parsed: Bool,
        license: String? = nil
    ) -> DeepConfiguration {
        let config = DeepConfiguration(context: context)
        config.entityId = UUID()
        config.demo = demo
        config.file_ = fileName.flatMap { URL(string: $0) }
        config.modelTypeString = typeString
        config.modelTypeParsed = parsed
        config.license = license
        config.phaseOutTime = 0.5
        config.annotationColor = .red
        config.lifeCycle = .draft
        return config
    }

    private func backfiller(loader: any ModelMetadataLoading) -> ModelTypeBackfiller {
        ModelTypeBackfiller(dataController: dataController, defaults: defaults, loader: loader)
    }

    private func metadata(
        task: DeepDriverType = .detector,
        typeWasParsed: Bool = true,
        license: String? = "AGPL-3.0"
    ) -> ExtractedModelInfo {
        ExtractedModelInfo(
            modelVersion: nil,
            modelDescription: nil,
            author: nil,
            license: license,
            creationDateString: nil,
            task: task,
            typeWasParsed: typeWasParsed
        )
    }

    // MARK: - Tests

    /// A declared-type detector left `false` by migration is re-parsed, locked, and its stored type
    /// set to the authoritative parser value.
    func test_backfill_locksParserDecidedModel() async {
        // Stored as classify to prove the backfill also corrects a stale type to what the file declares.
        let config = seed(demo: false, fileName: "file:///tmp/aia0478-model.mlmodel", typeString: "classify", parsed: false)
        let loader = StubModelMetadataLoader(result: metadata())

        await backfiller(loader: loader).backfillIfNeeded()

        XCTAssertTrue(config.modelTypeParsed, "A parser-decided model must be locked after backfill")
        XCTAssertEqual(config.modelType, .detector, "The stored type must be corrected to the declared value")
        XCTAssertEqual(config.license, "AGPL-3.0")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The one-shot guard must be set")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey), "The license guard must be set")
        let calls = await loader.calls()
        XCTAssertEqual(calls, 1, "One metadata read must serve both backfill passes")
    }

    /// The AIA-0478 pass must run independently after AIA-0402 has already completed.
    func test_backfill_licenseRunsAfterTypeGuardAndLeavesTypeUntouched() async {
        defaults.set(true, forKey: ModelTypeBackfiller.defaultsKey)
        let config = seed(demo: false, fileName: "file:///tmp/aia0478-model.mlmodel", typeString: "classify", parsed: false)
        let loader = StubModelMetadataLoader(result: metadata(license: "MIT"))

        await backfiller(loader: loader).backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "The completed type pass must not re-derive the stored type")
        XCTAssertEqual(config.modelType, .classificator)
        XCTAssertEqual(config.license, "MIT", "The independent license pass must still populate legacy rows")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey))
        let calls = await loader.calls()
        XCTAssertEqual(calls, 1)
    }

    /// Once both guard flags are set, a later launch does not touch rows or load their files.
    func test_backfill_guardsPreventRerun() async {
        defaults.set(true, forKey: ModelTypeBackfiller.defaultsKey)
        defaults.set(true, forKey: ModelTypeBackfiller.licenseDefaultsKey)
        let config = seed(demo: false, fileName: "file:///tmp/aia0478-model.mlmodel", typeString: "detect", parsed: false)
        let loader = StubModelMetadataLoader(result: metadata())

        await backfiller(loader: loader).backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "The guards must short-circuit before any re-derivation")
        XCTAssertNil(config.license)
        let calls = await loader.calls()
        XCTAssertEqual(calls, 0)
    }

    /// A row whose file can't be resolved stays user-owned (editable); the guard still advances so
    /// the (pointless) re-parse isn't retried forever.
    func test_backfill_skipsUnresolvableFileButNormalizesLegacyBlankLicense() async {
        let config = seed(demo: false, fileName: nil, typeString: "detect", parsed: false, license: " \n ")
        let loader = StubModelMetadataLoader(result: metadata())

        await backfiller(loader: loader).backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "An unresolvable file must leave the row user-owned")
        XCTAssertNil(config.license, "Blank legacy metadata must not remain persisted as a fake license")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The guard must still be set")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey), "The license guard must still be set")

        // The upgrade scan is deliberately bounded: restoring the source later must not cause a
        // second compile/read once the first missing-file scan armed both guards.
        config.file_ = URL(string: "file:///tmp/aia0478-model.mlmodel")
        await backfiller(loader: loader).backfillIfNeeded()

        let calls = await loader.calls()
        XCTAssertEqual(calls, 0, "A completed missing-file scan must not be retried on a later launch")
    }

    /// A row whose metadata load throws must not be counted as scanned: the guards stay unarmed so
    /// the next launch retries the row instead of leaving it permanently without a license.
    func test_backfill_failedLoadLeavesGuardsUnarmedAndNextLaunchRetries() async {
        let config = seed(
            demo: false,
            fileName: "file:///tmp/aia0478-model.mlmodel",
            typeString: "classify",
            parsed: false
        )

        await backfiller(loader: FailingModelMetadataLoader()).backfillIfNeeded()

        XCTAssertFalse(config.modelTypeParsed, "A failed load must leave the row untouched")
        XCTAssertNil(config.license)
        XCTAssertFalse(
            defaults.bool(forKey: ModelTypeBackfiller.defaultsKey),
            "A scan with load failures must not arm the type guard"
        )
        XCTAssertFalse(
            defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey),
            "A scan with load failures must not arm the license guard"
        )

        // The next launch retries the same row and a clean scan completes both passes.
        await backfiller(loader: StubModelMetadataLoader(result: metadata())).backfillIfNeeded()

        XCTAssertTrue(config.modelTypeParsed, "The retried row must be locked once its load succeeds")
        XCTAssertEqual(config.license, "AGPL-3.0")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey))
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey))
    }

    /// A row that already carries both fields is not re-read or overwritten during the upgrade scan.
    func test_backfill_skipsRowsWithPersistedTypeAndLicense() async {
        let alreadyBackfilled = seed(
            demo: false,
            fileName: "file:///tmp/aia0478-model.mlmodel",
            typeString: "detect",
            parsed: true,
            license: "Proprietary"
        )
        let loader = StubModelMetadataLoader(result: metadata(license: "AGPL-3.0"))

        await backfiller(loader: loader).backfillIfNeeded()

        XCTAssertTrue(alreadyBackfilled.modelTypeParsed, "An already-locked row must be left untouched")
        XCTAssertEqual(alreadyBackfilled.modelType, .detector)
        XCTAssertEqual(alreadyBackfilled.license, "Proprietary")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.defaultsKey), "The guard must be set")
        XCTAssertTrue(defaults.bool(forKey: ModelTypeBackfiller.licenseDefaultsKey), "The license guard must be set")
        let calls = await loader.calls()
        XCTAssertEqual(calls, 0)
    }
}
