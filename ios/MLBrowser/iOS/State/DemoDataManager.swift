//
//  DemoDataManager.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import OSLog

@MainActor
final class DemoDataManager {
    // The Czech ČÚZK "Analýzy výškopisu" DMR 5G grayscale-hillshade relief page, seeded into the
    // demo history and loaded into the address bar when the onboarding tour starts (AIA-0333) — the
    // tour's first step points at it. (Replaces the Bavaria geoportal, which had upstream outages.)
    //
    // AIA-0757 pins it to Vladař rather than the whole country. The step tells the user to load a
    // site, and an unzoomed national relief map gives the detection models nothing to find — so the
    // very next step, "switch a model on", appeared to do nothing. The `extent` frames a hillfort
    // where the demo models actually detect something, and `o=1` turns the relief layer fully on.
    //
    // Note the reach of this change: an existing install keeps the old address in its history, since
    // `createBrowsingHistoryIfNeeded` seeds only into an empty history. A fresh install — and any
    // onboarding replay — gets the new page.
    //
    // Known-valid literal URL; the force-unwrap can't fail.
    // swiftlint:disable:next force_unwrapping
    static let onboardingDemoPage = URL(
        string: "https://ags.cuzk.cz/av/?extent=-831002.3241535446,-1032569.7200186695,-826473.7490963945,-1029973.3903260101&zvd=dmr5g&rf=GrayscaleHillshade&o=1"
    )!

    let dataController: DataController

    /// Re-entrancy guard to ensure demo data creation runs only once
    private var isCreatingDemoData = false

    init(dataController: DataController) {
        self.dataController = dataController
    }

    /// Creates demo data if none exists. Call AFTER Core Data is ready.
    func createDemoDataIfNeeded() async {
        // Re-entrancy guard: prevent concurrent execution
        guard !isCreatingDemoData else {
            LoggingPolicy.debug("Demo data creation already in progress, skipping", logger: .configuration)
            return
        }
        isCreatingDemoData = true
        defer { isCreatingDemoData = false }

        let context = dataController.container.viewContext

        // Single source of truth: check Core Data directly
        let existingDemos = DeepConfiguration.selectAll(in: context).filter { $0.demo }
        guard existingDemos.isEmpty else {
            LoggingPolicy.debug("Demo configurations already exist (\(existingDemos.count) found), skipping creation", logger: .configuration)
            return
        }

        LoggingPolicy.info("Creating demo configurations", logger: .configuration)
        
        await loadModelOne()
        await loadModelTwo()
        await loadModelThree()
        await createBrowsingHistoryIfNeeded()
        
        LoggingPolicy.info("Demo data creation complete", logger: .configuration)
    }
    
    /// Deletes all browsing history asynchronously.
    ///
    /// Use this method when you need to wait for the deletion to complete
    /// or handle potential errors.
    ///
    /// - Returns: Completes when the deletion operation finishes.
    func deleteBrowsingHistory() async {
        LoggingPolicy.info("Deleting all browsing history", logger: .state)
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Use background context for batch delete to avoid blocking UI
            // Use mergeByPropertyStoreTrump for destructive operations to ensure
            // store changes (deletions) take precedence
            // The viewContext reference is only handed to
            // mergeChanges(fromRemoteContextSave:into:), which is safe to call cross-queue.
            let viewContext = dataController.container.viewContext
            dataController.performBackgroundTask(mergePolicy: .mergeByPropertyStoreTrump) { context in
                // Use defer to ensure continuation is always resumed exactly once
                defer { continuation.resume() }

                do {
                    // Merge into the viewContext too: batch deletes bypass context saves, so
                    // automaticallyMergesChangesFromParent does NOT propagate them.
                    try WebHistoryEntry.deleteAll(in: context, mergingInto: [viewContext])
                    // The visit trail belongs to the browsing history; clear it together.
                    try WebVisit.deleteAll(in: context, mergingInto: [viewContext])
                    LoggingPolicy.debug("Browsing history deletion completed on background context", logger: .state)
                } catch {
                    LoggingPolicy.error("Browsing history deletion failed", error: error, logger: .state)
                }
            }
        }
    }
    
    private func createBrowsingHistoryIfNeeded() async {
        // Check count on viewContext first (fast check)
        let viewContext = dataController.container.viewContext
        guard WebHistoryEntry.count(in: viewContext) == 0 else { return }

        LoggingPolicy.info("Creating initial browsing history with demo pages", logger: .state)
        let pages: [String] = [
            // Wind-Atlas Hessen. The old windrosen.hessen.de deep link now 301→302 redirects
            // down to http:// (ATS-blocked → fails to load); this https URL serves a single 200
            // with no downgrade (AIA-0342).
            "https://umweltdaten.hessen.de/mapapps/resources/apps/windatlas/index.html?lang=en",
            "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren",
            Self.onboardingDemoPage.absoluteString,
            "https://www.geoland.at/webgisviewer/geoland/map/Geoland_Viewer/Geoland?fbclid=IwAR3hGN0L39GRBEXx1rfdBjo_M5HthBjurMS6fR50JnEJ1aDJ2pmblfTGHoo",
            "https://houseprices.io/lab/lidar/map"
        ]

        // Use background context for batch creation to avoid blocking UI
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataController.performBackgroundTask { context in
                // Use defer to ensure continuation is always resumed exactly once
                defer { continuation.resume() }

                // Double-check count on background context to avoid race condition
                guard WebHistoryEntry.count(in: context) == 0 else {
                    LoggingPolicy.debug(
                        "Skipping demo browsing history creation: entries already exist in background context (race condition avoided)",
                        logger: .state
                    )
                    return
                }

                LoggingPolicy.debug("Creating demo browsing history entries on background context", logger: .state)

                for page in pages {
                    let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: context)
                    newHistorEntry.bookmarked = false
                    newHistorEntry.creationDate_ = .now
                    newHistorEntry.entityId = UUID()
                    newHistorEntry.page = URL(string: page)
                    // Lifecycle: transition to draft before validation, then to ready if valid
                    // If validation fails, the entity is deleted (brief inconsistent state is acceptable)
                    newHistorEntry.transition(to: .draft)
                    do {
                        try newHistorEntry.validateForInsert()
                        newHistorEntry.transition(to: .ready)
                    } catch {
                        context.delete(newHistorEntry)
                        LoggingPolicy.error("Web history entry validation failed", error: error, logger: .state)
                    }
                }

                // Single save after all entries are created (batched)
                do {
                    try WebHistoryEntry.save(in: context)
                    LoggingPolicy.debug("Browsing history creation completed on background context", logger: .state)
                } catch {
                    LoggingPolicy.error("Failed to save demo browsing history", error: error, logger: .state)
                }
            }
        }
    }
    
    /// Bundle resource names of the demo models — shared with tests so a rename
    /// can't silently diverge production and test lookups (review: stringly-typed).
    enum DemoModelResource {
        static let aiArcheology = "AIArcheology"
        static let hroudaDetector = "HroudaDetector15"
        static let fastViT = "FastViTT8F16"
    }

    /// Shared demo-model loader: bundle lookup + error logging + seeding.
    /// Warning: models are used as mlmodelc in the bundle when handled from Xcode.
    private func loadDemoModel(resourceName: String, enabled: Bool = false) async {
        guard let urlInBundle = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") else {
            LoggingPolicy.error("Cannot locate \(resourceName) demo model in bundle", logger: .configuration)
            return
        }
        await loadModel(from: urlInBundle, enabled: enabled)
    }

    private func loadModelOne() async {
        await loadDemoModel(resourceName: DemoModelResource.aiArcheology)
    }

    private func loadModelTwo() async {
        await loadDemoModel(resourceName: DemoModelResource.hroudaDetector)
    }

    private func loadModelThree() async {
        // FastViT-T8 (Apple's model gallery, F16, ~8 MB) is a TEST-ONLY asset
        // (owner decision, AIA-0374): it ships under Apple's custom ML license and
        // must not be part of the installation package. The resource is excluded
        // from Release builds (EXCLUDED_SOURCE_FILE_NAMES) and seeds only when a
        // UI test requests it via launch config — production (and normal Debug
        // runs) never see it. Unit tests load it from the bundle directly.
        guard AppEnvironment.isRunningUITests,
              UITestLaunchConfiguration.fromEnvironment?.enableClassifyDemo == true else { return }
        await loadDemoModel(resourceName: DemoModelResource.fastViT, enabled: true)
    }

    /// Loads a demo model and creates a Core Data configuration for it.
    ///
    /// Model metadata extraction is performed via ModelLoadingService (off MainActor),
    /// while Core Data entity creation remains on MainActor.
    private func loadModel(from file: URL, enabled: Bool = false) async {
        var urlToPossibleDirectory = file.absoluteString
        if urlToPossibleDirectory.hasSuffix("/") {
            urlToPossibleDirectory.removeLast()
        }

        guard let url = URL(string: urlToPossibleDirectory) else {
            LoggingPolicy.error("Failed to create URL from string for demo model", logger: .configuration)
            return
        }

        LoggingPolicy.debug("Loading MLModel from \(url.lastPathComponent)", logger: .configuration)

        // Phase 1: Extract metadata using ModelLoadingService (off MainActor)
        let extractedInfo: ExtractedModelInfo
        do {
            let service = ModelLoadingService()
            extractedInfo = try await service.loadAndExtractMetadata(from: url, demo: true)
        } catch {
            LoggingPolicy.error("Failed to load demo model metadata", error: error, logger: .configuration)
            return
        }

        // Phase 2: Create Core Data entity (on MainActor - we're already here)
        let configuration = DeepConfiguration.create(in: dataController.container.viewContext)
        configuration.demo = true
        configuration.modelVersion = extractedInfo.modelVersion
        configuration.modelDescription = extractedInfo.modelDescription
        configuration.author = extractedInfo.author
        configuration.license = extractedInfo.license
        configuration.creationDate_ = extractedInfo.creationDateString?.toDate(.createMl)
        configuration.modelType = extractedInfo.task
        configuration.modelTypeParsed = extractedInfo.typeWasParsed
        configuration.phaseOutTime = 2
        configuration.selectedSymbol = .circle
        configuration.file_ = URL(string: url.lastPathComponent)
        configuration.enabled = enabled
        configuration.transition(to: .draft)
        configuration.transition(to: .ready)
        do {
            try DeepConfiguration.save(in: self.dataController.container.viewContext)
        } catch {
            LoggingPolicy.error("Failed to save demo configuration", error: error, logger: .configuration)
            // Remove the pending insert so a later, unrelated save cannot persist a
            // half-configured demo entry. (No context-wide rollback: it would discard
            // unrelated pending changes.)
            self.dataController.container.viewContext.delete(configuration)
            return
        }
        LoggingPolicy.debug("Demo configuration life cycle: \(configuration.lifeCycle)", logger: .configuration)
        LoggingPolicy.info("Demo configuration created successfully for \(url.lastPathComponent)", logger: .configuration)
    }
}
