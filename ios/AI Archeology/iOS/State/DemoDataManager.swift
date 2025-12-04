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
    let settings: Settings
    let dataController: DataController
    
    init(settings: Settings, dataController: DataController) {
        self.settings = settings
        self.dataController = dataController
    }
    
    func createDemoEntities() {
        if settings.isFirstLaunch {
            Logger.app.logInfo("First launch detected, creating demo entities")
            settings.isFirstLaunchMarked = true
            settings.isFirstLaunch = false
            
            // Create the context
            _ = self.dataController.container.viewContext
            Task {
                // and give the context time to be ready
                try await Task.sleep(nanoseconds: 100_000_000)
                createDemoConfigurations()
                await createBrowsingHistory()
            }
        }
    }
    
    /// Load the configuration only if the demo configurations do not exist yet
    func createDemoConfigurations() {
		let demosDoNotExist = DeepConfiguration
			.selectAll(in: dataController.container.viewContext)
			.filter { $0.demo }
			.isEmpty
			
		guard demosDoNotExist else {
			Logger.configuration.logInfo("Demo configurations already exist, skipping creation")
			return
		}
		
        Task {
            await loadModelOne()
            await loadModelTwo()
        }
    }
    
    func deleteBrowsingHistory() {
        Logger.state.logInfo("Deleting all browsing history")
        WebHistoryEntry.deleteAll(in: dataController.container.viewContext, executeAndMerge: true)
    }
    
    
    func createBrowsingHistory() async {
        let history = WebHistoryEntry.selectAll(in: dataController.container.viewContext)
        guard history.isEmpty, settings.isFirstLaunchMarked else { return }
        
        Logger.state.logInfo("Creating initial browsing history with demo pages")
        let pages: [String] = [
            "https://windrosen.hessen.de/mapapps/resources/apps/windrosen/index.html?lang=en&vm=2D&s=1500000&r=0&c=550000%2C5595000&bm=orthofotos_schummerung",
            "https://zbgis.skgeodesy.sk/mkzbgis/sk/teren",
            "https://geoportal.bayern.de/bayernatlas/?topic=ba&lang=de&bgLayer=voidLayer&zoom=3&w=100%25&h=500px&E=651597.27&N=5461429.48&layers=KML%7C%7Chttps:%2F%2Fwww.geodaten.bayern.de%2Fdownload%2Fuebersicht_DGM%2FLaserscanningbefliegungen.kml%7C%7Ctrue,relief_t&catalogNodes=11,12,121&layers_visibility=false,true",
            "https://www.geoland.at/webgisviewer/geoland/map/Geoland_Viewer/Geoland?fbclid=IwAR3hGN0L39GRBEXx1rfdBjo_M5HthBjurMS6fR50JnEJ1aDJ2pmblfTGHoo",
            "https://houseprices.io/lab/lidar/map",
            "https://ags.cuzk.cz/av/?zvd=dmr5g&rf=GrayscaleHillshade&o=0"
        ]
        
        for page in pages {
            let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: dataController.container.viewContext)
            newHistorEntry.bookmarked = false
            newHistorEntry.creationDate_ = .now
            newHistorEntry.entityId = UUID()
            newHistorEntry.page = URL(string:page)
            newHistorEntry.transition(to: .draft)
            do {
                try newHistorEntry.validateForInsert()
            }
            catch {
                WebHistoryEntry.delete(newHistorEntry, in: dataController.container.viewContext)
                Logger.state.logError("Web history entry validation failed: \(error.localizedDescription)")
                continue
            }
            newHistorEntry.transition(to: .ready)
            WebHistoryEntry.save(in: self.dataController.container.viewContext)
        }
    }
    
    private func loadModelOne() async {
        // Warning: models are used as mlmodelc in the bundle when handled from xcode
        guard let urlInBundle = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            Logger.configuration.logError("Cannot locate AIArcheology demo model in bundle")
            return
        }
        
        await loadModel(from: urlInBundle)
    }
    
    private func loadModelTwo() async {
        // Warning: models are used as mlmodelc in the bundle when handled from xcode
        guard let urlInBundle = Bundle.main.url(forResource: "HroudaDetector15", withExtension: "mlmodelc") else {
            Logger.configuration.logError("Cannot locate HroudaDetector15 demo model in bundle")
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
            Logger.configuration.logError("Failed to create URL from string for demo model")
            return
        }
        
        Logger.configuration.logInfo("Loading demo model from \(url.lastPathComponent)")
        
        var detector: MLModel?
        let demo = true
        
        do {
            detector = try await Detector.loadModel(from: url, demo: demo)
        }
        catch {
            Logger.configuration.logError("Failed to load demo detector model: \(error.localizedDescription)")
            return
        }
        
        guard let metadata = detector?.modelDescription.metadata else {
            Logger.configuration.logWarning("Demo model loaded but has no metadata")
            return
        }
        let parser = MLModelMetadataParser(metadata: metadata)
        
        let configuration = DeepConfiguration.create(in: dataController.container.viewContext)
        configuration.demo = true
        configuration.annotationColor = .yellow
        configuration.modelVersion = parser.value(for: .versionString) as? String
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
        Logger.configuration.logTrace("Demo configuration life cycle: \(configuration.lifeCycle)")
        Logger.configuration.logInfo("Demo configuration created successfully for \(url.lastPathComponent)")
    }
}
