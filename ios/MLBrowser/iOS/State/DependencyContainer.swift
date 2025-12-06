//
//  DependencyContainer.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import Combine

@MainActor
class DependencyContainer {
	static let shared = DependencyContainer()
    
    lazy var dataController: DataController = {
        return DataController()
    }()
    
    lazy var settings: Settings = {
        return Settings()
    }()
    
    lazy var snapState: SnapState = {
        return SnapState(settings: self.settings)
    }()
    
    lazy var deepState: DeepState = {
        return DeepState(dataController: self.dataController)
    }()
    
    lazy var downloader: Downloader = {
        return Downloader(dataController: self.dataController)
    }()
    
    lazy var demoDataManager: DemoDataManager = {
        return DemoDataManager(dataController: self.dataController)
    }()
    
    private init() {}
}
