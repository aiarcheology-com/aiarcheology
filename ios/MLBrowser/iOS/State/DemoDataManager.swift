//
//  DemoDataManager.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import Vision
import OSLog
import CoreML

@MainActor
final class DemoDataManager {
    let dataController: DataController
    
    init(dataController: DataController) {
        self.dataController = dataController
    }
    
    /// Creates demo data if none exists. Call AFTER Core Data is ready.
    func createDemoDataIfNeeded() async {
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
            dataController.performBackgroundTask(mergePolicy: .mergeByPropertyStoreTrump) { context in
                // Use defer to ensure continuation is always resumed exactly once
                defer { continuation.resume() }
                
                WebHistoryEntry.deleteAll(in: context, executeAndMerge: true)
                LoggingPolicy.debug("Browsing history deletion completed on background context", logger: .state)
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
                WebHistoryEntry.save(in: context)
                LoggingPolicy.debug("Browsing history creation completed on background context", logger: .state)
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
    
    // TODO: make this nicer, unify with the deep configuration form
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
        
        var detector: MLModel?
        let demo = true
        
        do {
            detector = try await Detector.loadModel(from: url, demo: demo)
        }
        catch {
            LoggingPolicy.error("Failed to load demo detector model", error: error, logger: .configuration)
            return
        }
        
        guard let metadata = detector?.modelDescription.metadata else {
            LoggingPolicy.warning("Demo model loaded but has no metadata", logger: .configuration)
            return
        }
        let parser = MLModelMetadataParser(metadata: metadata)
        
        let configuration = DeepConfiguration.create(in: dataController.container.viewContext)
        configuration.demo = true
        configuration.annotationColor = .yellow
        configuration.modelVersion = parser.modelVersion
        configuration.modelDescription = parser.value(for: .description) as? String
        configuration.author = parser.value(for: .author) as? String
        configuration.creationDate_ = (parser.value(for: .date) as? String)?.toDate(.createMl)
        configuration.modelType = parser.task
        configuration.phaseOutTime = 2
        configuration.selectedSymbol = .circle
        configuration.file_ = URL(string: url.lastPathComponent)
        configuration.enabled = false
        configuration.transition(to: .draft)
        configuration.transition(to: .ready)
        DeepConfiguration.save(in: self.dataController.container.viewContext)
        LoggingPolicy.debug("Demo configuration life cycle: \(configuration.lifeCycle)", logger: .configuration)
        LoggingPolicy.info("Demo configuration created successfully for \(url.lastPathComponent)", logger: .configuration)
    }
}
