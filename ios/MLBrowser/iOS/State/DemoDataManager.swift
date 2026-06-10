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
            // nonisolated(unsafe): the viewContext reference is only handed to
            // mergeChanges(fromRemoteContextSave:into:), which is safe to call cross-queue.
            nonisolated(unsafe) let viewContext = dataController.container.viewContext
            dataController.performBackgroundTask(mergePolicy: .mergeByPropertyStoreTrump) { context in
                // Use defer to ensure continuation is always resumed exactly once
                defer { continuation.resume() }

                do {
                    // Merge into the viewContext too: batch deletes bypass context saves, so
                    // automaticallyMergesChangesFromParent does NOT propagate them.
                    try WebHistoryEntry.deleteAll(in: context, mergingInto: [viewContext])
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
            "https://windrosen.hessen.de/mapapps/resources/apps/windrosen/index.html?lang=en&vm=2D&s=1500000&r=0&c=550000%2C5595000&bm=orthofotos_schummerung",
            "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren",
            "https://geoportal.bayern.de/bayernatlas/?topic=ba&lang=de&bgLayer=voidLayer&zoom=3&w=100%25&h=500px&E=651597.27&N=5461429.48&layers=KML%7C%7Chttps:%2F%2Fwww.geodaten.bayern.de%2Fdownload%2Fuebersicht_DGM%2FLaserscanningbefliegungen.kml%7C%7Ctrue,relief_t&catalogNodes=11,12,121&layers_visibility=false,true",
            "https://www.geoland.at/webgisviewer/geoland/map/Geoland_Viewer/Geoland?fbclid=IwAR3hGN0L39GRBEXx1rfdBjo_M5HthBjurMS6fR50JnEJ1aDJ2pmblfTGHoo",
            "https://houseprices.io/lab/lidar/map",
            "https://ags.cuzk.cz/av/?zvd=dmr5g&rf=GrayscaleHillshade&o=0"
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
    
    private func loadModelOne() async {
        // Warning: models are used as mlmodelc in the bundle when handled from xcode
        guard let urlInBundle = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            LoggingPolicy.error("Cannot locate AIArcheology demo model in bundle", logger: .configuration)
            return
        }
        
        await loadModel(from: urlInBundle)
    }
    
    private func loadModelTwo() async {
        // Warning: models are used as mlmodelc in the bundle when handled from xcode
        guard let urlInBundle = Bundle.main.url(forResource: "HroudaDetector15", withExtension: "mlmodelc") else {
            LoggingPolicy.error("Cannot locate HroudaDetector15 demo model in bundle", logger: .configuration)
            return
        }
        
        await loadModel(from: urlInBundle)
    }
    
    /// Loads a demo model and creates a Core Data configuration for it.
    ///
    /// Model metadata extraction is performed via ModelLoadingService (off MainActor),
    /// while Core Data entity creation remains on MainActor.
    private func loadModel(from file: URL) async {
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
        configuration.creationDate_ = extractedInfo.creationDateString?.toDate(.createMl)
        configuration.modelType = extractedInfo.task
        configuration.phaseOutTime = 2
        configuration.selectedSymbol = .circle
        configuration.file_ = URL(string: url.lastPathComponent)
        configuration.enabled = false
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
