//
//  DependencyContainer.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import Combine

protocol DataControlling: AnyObject {
    var container: NSPersistentContainer { get }
}

@MainActor
protocol SettingsProviding: ObservableObject {
    var isFirstLaunch: Bool { get set }
    var isFirstLaunchMarked: Bool { get set }
    var snapFrequency: Double { get }
    var applicationResetButtonToggle: Bool { get set }
    var isDetectionPaused: Bool { get set }
    var showIdentifiers: Bool { get set }
    var lastPage: URL? { get set }
    var reopenLastPage: Bool { get set }
    var defaultPage: URL? { get set }
    var historySize: Int { get set }
    var keepSlideShowActive: Bool { get set }
    var snapAfterAppStart: Bool { get set }
    func reset()
}

@MainActor
protocol SnapStateManaging: ObservableObject {
    var delayedTimer: Bool { get set }
    var combinedPublishers: AnyPublisher<Void, Never> { get }
    func startTimer()
    func stopTimer()
}

@MainActor
protocol DeepStateManaging: ObservableObject {
    var drivers: DeepDrivers { get }
    var frame: CGRect { get set }
    var newConfiguration: DeepConfiguration? { get }
    var deepStateErrorPublisher: Published<Error?>.Publisher { get }
    func cleanupTemporaryConfiguration()
    func createTemportaryConfiguration()
    func selectConfiguration(_ entityId: UUID) -> DeepConfiguration?
    func reset()
}

@MainActor
protocol Downloading: ObservableObject {
    var activeDownloads: [UUID: ActiveDownload] { get }
    func progressPublisher(for itemId: UUID?) -> AnyPublisher<Double, Never>
    func totalBytesWrittenPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never>
    func totalBytesExpectedPublisher(for itemId: UUID?) -> AnyPublisher<Int, Never>
    func downloadTapped(_ item: DownloadItem)
    func cancelTapped(_ item: DownloadItem)
}

@MainActor
protocol DemoDataManaging {
    func createDemoEntities()
    func deleteBrowsingHistory()
}

@MainActor
class DependencyContainer {
	static let shared = DependencyContainer()
    
    lazy var dataController: DataControlling = {
        return DataController()
    }()
    
    lazy var settings: any SettingsProviding = {
        return Settings()
    }()
    
    lazy var snapState: any SnapStateManaging = {
        return SnapState(settings: self.settings)
    }()
    
    lazy var deepState: any DeepStateManaging = {
        return DeepState(dataController: self.dataController)
    }()
    
    lazy var downloader: any Downloading = {
        return Downloader(dataController: self.dataController)
    }()
    
    lazy var demoDataManager: DemoDataManaging = {
        return DemoDataManager(settings: self.settings, dataController: self.dataController)
    }()
    
    private init() {}
}
