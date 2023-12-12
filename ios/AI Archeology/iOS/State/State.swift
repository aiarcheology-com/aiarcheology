//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation

enum AppMode: Int, Codable, Hashable, Identifiable {
	var id: Self { self }
    case web
    case gallery
    // case cloud
    // case camera
	// case stream
	// case api
	static var tabOrder: [AppMode] { [.web] }
}

class AppState: ObservableObject {
	lazy var guide = Guide(appState: self)
	lazy var snap = SnapState(appState: self)
	lazy var renderer = DefaultRenderer(appState: self)
	lazy var webViewRenderer = WebViewRenderer(appState: self)
	lazy var deep = DeepState(appState: self)
	lazy var dataController = DataController(appState: self)
	lazy var settings = Settings(appState: self)
	lazy var snapAdjustment = SnapAdjustment(appState: self)

	init() {
		createDemoEntities()
	}

	func createDemoEntities() {
		if settings.isFirstLaunch {
			settings.isFirstLaunchMarked = true
			settings.isFirstLaunch = false
			createDemoConfigurations()
			createBrowsingHistory()
		}
	}

	func createDemoConfigurations() {
		loadModelOne()
		loadModelTwo()
	}

	func deleteBrowsingHistory() {
		WebHistoryEntry.deleteAll(in: dataController.container.viewContext, executeAndMerge: true)
	}


	func createBrowsingHistory() {
		let history = WebHistoryEntry.getAll(in: dataController.container.viewContext)
		guard history.isEmpty, settings.isFirstLaunchMarked else { return }

		let pages: [String] = [
			"https://windrosen.hessen.de/mapapps/resources/apps/windrosen/index.html?lang=en&vm=2D&s=1500000&r=0&c=550000%2C5595000&bm=orthofotos_schummerung",
			"https://zbgis.skgeodesy.sk/mkzbgis/sk/teren",
			"https://geoportal.bayern.de/bayernatlas/?topic=ba&lang=de&bgLayer=voidLayer&zoom=3&w=100%25&h=500px&E=651597.27&N=5461429.48&layers=KML%7C%7Chttps:%2F%2Fwww.geodaten.bayern.de%2Fdownload%2Fuebersicht_DGM%2FLaserscanningbefliegungen.kml%7C%7Ctrue,relief_t&catalogNodes=11,12,121&layers_visibility=false,true",
			"https://www.geoland.at/webgisviewer/geoland/map/Geoland_Viewer/Geoland?fbclid=IwAR3hGN0L39GRBEXx1rfdBjo_M5HthBjurMS6fR50JnEJ1aDJ2pmblfTGHoo",
			"https://houseprices.io/lab/lidar/map",
			"https://ags.cuzk.cz/av/?zvd=dmr5g&rf=GrayscaleHillshade&o=0"
		]

		pages.forEach { page in
			let newHistorEntry: WebHistoryEntry = WebHistoryEntry.create(in: dataController.container.viewContext)
			newHistorEntry.bookmarked = false
			newHistorEntry.creationDate_ = .now
			newHistorEntry.entityId = UUID()
			newHistorEntry.page = URL(string:page)
			do {
				try newHistorEntry.validateForInsert()
			}
			catch let error {
				WebHistoryEntry.delete(newHistorEntry, in: dataController.container.viewContext)
				assert(false, "The new web history entry is not valid and can not be stored \(error)" )
				return
			}

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
				WebHistoryEntry.save(in: self.dataController.container.viewContext)
			}
		}
	}

	private func loadModelOne() {
		Task {
			// Warning: models are used as mlmodelc in the bundle when handled from xcode
			guard let urlInBundle = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
				assert(false, "Can not locate the model demo file in the bundle.")
				return
			}

			await loadModel(from: urlInBundle)
		}
	}

	private func loadModelTwo() {
		Task {
			// Warning: models are used as mlmodelc in the bundle when handled from xcode
			guard let urlInBundle = Bundle.main.url(forResource: "HroudaDetector15", withExtension: "mlmodelc") else {
				assert(false, "Can not locate the model demo file in the bundle.")
				return
			}

			await loadModel(from: urlInBundle)
		}
	}

	// TODO: make this nicer, unify with the deep configuration form
	private func loadModel(from file: URL) async {
		var urlToPossibleDirectory = file.absoluteString
		if urlToPossibleDirectory.hasSuffix("/") {
			urlToPossibleDirectory.removeLast()
		}

		guard let url = URL(string: urlToPossibleDirectory) else {
			assert(false, "Error in creating URL from string.")
			return
		}


		let id = UUID()
		var detector: MLModel?
		let demo = true

		do {
			detector = try await Detector.loadModel(from: url, demo: demo)
		}
		catch {
			assert(false, "Demo detector can not be loaded.")
			return
		}

		guard let metadata = detector?.modelDescription.metadata else { return }
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
		configuration.entityId = id
		configuration.enabled = false
		Task {
			DeepConfiguration.save(in: self.dataController.container.viewContext)
		}
	}
}

class SnapAdjustment: ObservableObject {
	unowned var appState: AppState
	static let defaultBrightness = 0.0
	static let defaultContrast = 1.0
	static let defaultSaturation = 1.0
	init(appState: AppState) {
		self.appState = appState
	}

	// TODO: Possibly store together in the Page History
	@Published var brightness: Double = defaultBrightness
	@Published var contrast: Double = defaultContrast
	@Published var saturation: Double = defaultSaturation
}

protocol Validatable {
	func validate() throws
}

enum ValidationError: Error {
	case invalidData(String)
}

class Settings: ObservableObject, Validatable {
	unowned var appState: AppState
	private enum UserDefaultsKeys {
		static let isDetectionPaused = "isDetectionPaused"
		static let keepSlideShowActive = "keepSlideShowActive"
		static let reopenLastPage = "reopenLastPage"
		static let isFirstLaunch = "isFirstLaunch"
		static let showIdentifiers = "showIdentifiers"
		static let snapAfterAppStart = "snapAfterAppStart"
		static let snapFrequency = "snapFrequency"
		static let resetHistory = "resetHistory"
		static let sizeHistory = "sizeHistory"
		static let defaultPage = "defaultPage"
		static let removeAnnotationOnDrag = "removeAnnotationOnDrag"
		static let entityId = "entityId"
	}

	public var isFirstLaunchMarked: Bool = false

	@Published public var isDetectionPaused: Bool = false

	@Published public var keepSlideShowActive: Bool {
		didSet {
			UserDefaults.standard.set(keepSlideShowActive, forKey: UserDefaultsKeys.keepSlideShowActive)
		}
	}

	@Published public var applicationResetButtonToggle: Bool = false

	@Published public var historySize: Int {
		didSet {
			UserDefaults.standard.set(historySize, forKey: UserDefaultsKeys.sizeHistory)
		}
	}

	@Published public var snapAfterAppStart: Bool {
		didSet {
			UserDefaults.standard.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
		}
	}

	@Published public var reopenLastPage: Bool {
		didSet {
			UserDefaults.standard.set(reopenLastPage, forKey: UserDefaultsKeys.reopenLastPage)
		}
	}


	@Published public var snapFrequency: Double {
		didSet {
			UserDefaults.standard.set(snapFrequency, forKey: UserDefaultsKeys.snapFrequency)
		}
	}

	@Published public var resetHistory: Bool {
		didSet {
			UserDefaults.standard.set(resetHistory, forKey: UserDefaultsKeys.resetHistory)
		}
	}

	@Published public var defaultPage: URL? {
		didSet {
			UserDefaults.standard.set(defaultPage, forKey: UserDefaultsKeys.defaultPage)
		}
	}

	@Published public var removeAnnotationOnDrag: Bool {
		didSet {
			UserDefaults.standard.set(removeAnnotationOnDrag, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		}
	}

	@Published public var showIdentifiers: Bool {
		didSet {
			UserDefaults.standard.set(showIdentifiers, forKey: UserDefaultsKeys.showIdentifiers)
		}
	}

	@Published public var entityId: UUID? {
		didSet {
			UserDefaults.standard.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		}
	}

	@Published public var isFirstLaunch: Bool { // is being reseted in MLBrowser
		didSet {
			UserDefaults.standard.set(isFirstLaunch, forKey: UserDefaultsKeys.isFirstLaunch)
		}
	}

	init(appState: AppState) {
		self.appState = appState

		let defaultValues: [String: Any] = [
			UserDefaultsKeys.keepSlideShowActive: true,
			UserDefaultsKeys.sizeHistory: 30,
			UserDefaultsKeys.reopenLastPage: false,
			UserDefaultsKeys.isFirstLaunch: true,
			UserDefaultsKeys.showIdentifiers: false,
			UserDefaultsKeys.snapAfterAppStart: false,
			UserDefaultsKeys.snapFrequency: 3.0,
			UserDefaultsKeys.resetHistory: false,
			UserDefaultsKeys.defaultPage: URL(string: "https://www.google.com")!,
			UserDefaultsKeys.removeAnnotationOnDrag: false,
			UserDefaultsKeys.entityId: UUID().uuidString
		]

			// Register default values
		UserDefaults.standard.register(defaults: defaultValues)
		self.keepSlideShowActive = UserDefaults.standard.bool(forKey: UserDefaultsKeys.keepSlideShowActive)
		self.historySize = UserDefaults.standard.integer(forKey: UserDefaultsKeys.sizeHistory)
		self.reopenLastPage = UserDefaults.standard.bool(forKey: UserDefaultsKeys.reopenLastPage)
		self.isFirstLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isFirstLaunch)
		self.showIdentifiers = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showIdentifiers)
		self.snapAfterAppStart = UserDefaults.standard.bool(forKey: UserDefaultsKeys.snapAfterAppStart)
		self.snapFrequency = UserDefaults.standard.double(forKey: UserDefaultsKeys.snapFrequency)
		self.resetHistory = UserDefaults.standard.bool(forKey: UserDefaultsKeys.resetHistory)
		self.defaultPage = UserDefaults.standard.url(forKey: UserDefaultsKeys.defaultPage)
		self.removeAnnotationOnDrag = UserDefaults.standard.bool(forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		if let uuidString = UserDefaults.standard.string(forKey: UserDefaultsKeys.entityId),
		   let uuid = UUID(uuidString: uuidString) {
			self.entityId = uuid
		}
	}

	func validate() throws {
		if (snapFrequency >= 1.0 && snapFrequency <= 10.0).not {
			throw ValidationError.invalidData("Settings's snapFrequency is required between 1.0 and 10.0!")
		}
		if defaultPage.isNotNil &&
		   defaultPage?.absoluteString.isEmpty == false &&
			(defaultPage?.absoluteString.browserInputType == .url).not {
			throw ValidationError.invalidData("Settings's defaultPage with valid URL is required.")
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw ValidationError.invalidData("Settings's entityId is required.")
		}
	}

	func reset() {
		self.isDetectionPaused = false
		self.keepSlideShowActive = true
		self.historySize = 30
		self.reopenLastPage = false
		self.isFirstLaunchMarked = false
		self.isFirstLaunch = true
		self.showIdentifiers = false
		self.snapAfterAppStart = false
		self.snapFrequency = 3.0
		self.resetHistory = false
		self.defaultPage = URL(string: "https://www.google.com")
		self.removeAnnotationOnDrag = false
		self.entityId = UUID()
		UserDefaults.standard.set(true, forKey: UserDefaultsKeys.keepSlideShowActive)
		UserDefaults.standard.set(30, forKey: UserDefaultsKeys.sizeHistory)
		UserDefaults.standard.set(false, forKey: UserDefaultsKeys.reopenLastPage)
		UserDefaults.standard.set(true, forKey: UserDefaultsKeys.isFirstLaunch)
		UserDefaults.standard.set(false, forKey: UserDefaultsKeys.showIdentifiers)
		UserDefaults.standard.set(false, forKey: UserDefaultsKeys.snapAfterAppStart)
		UserDefaults.standard.set(3.0, forKey: UserDefaultsKeys.snapFrequency)
		UserDefaults.standard.set(false, forKey: UserDefaultsKeys.resetHistory)
		UserDefaults.standard.set(self.defaultPage, forKey: UserDefaultsKeys.defaultPage)
		UserDefaults.standard.set(false, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		UserDefaults.standard.set(self.entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
	}}


import Vision
import SwiftUI
// Drivers and DeepConfiguration have 1:1 relationship, and also
// both entities have the same UUID. DeepConfiguations are kept in CoreData.
// Drivers are loaded just in memory and un/registered with toggling the DeepConfiguration.enabled property.
class DeepState: ObservableObject {
	unowned var appState: AppState
	var frame: CGRect = .zero

	@Published var newConfiguration: DeepConfiguration?
	@Published var deepStateError: Error?
	var drivers = DeepDrivers()

	init(appState: AppState) {
		self.appState = appState
		observeDeepConfigurationChanges()

		let configurations = DeepConfiguration.getAll(in: appState.dataController.container.viewContext)
		do {
			try configurations.forEach { config in
				guard config.enabled == true else { return }
				guard let driver = try self.createDriver(from: config) else { return }
				self.register(driver: driver, along: config.modelTypeInternal)
			}
		}
		catch {
			// Send it to the upper layers to show the error to the user
			deepStateError = error
		}
	}

	private func createDriver(from configuration: DeepConfiguration) throws -> (any DeepDriver)? {
		guard let entityId = configuration.entityId else {
			assert(false, "The entityId of the configuration should be already initialised.")
			return nil
		}
		switch configuration.modelTypeInternal {
		case .detector: return try Detector(configuration: configuration, entityId: entityId)
		case .classificator: return try Classificator(configuration: configuration, entityId: entityId)
		}
	}

	// Actions:
	private func register(driver: any DeepDriver, along: DeepDriverType) {
		drivers.register(driver: driver, along: along)
	}

	private func updaterDriver(with configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else { return }
		drivers.update(driverId: entityId, configuration: configuration)
	}

	private func unregisterDriver(with configuration: DeepConfiguration) {
		guard let entityId = configuration.entityId else { return }
		drivers.unregister(driverId: entityId)
	}

	func createConfiguration() -> DeepConfiguration {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.create(in: context)
	}

	func updateConfiguration(_ entityId: UUID, updateClosure: (DeepConfiguration) -> Void) {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.update(entityId, in: context, with: updateClosure)
	}

	func deleteConfiguration(_ entityId: UUID) {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.delete(entityId, in: context)
	}

	func deleteConfiguration(_ entity: DeepConfiguration) {
		let context = appState.dataController.container.viewContext
		context.delete(entity)
	}

	func reset() {
		let context = appState.dataController.container.viewContext
		DeepConfiguration.deleteAll(in: context)
	}

	func selectConfiguration(_ entityId: UUID) -> DeepConfiguration? {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.select(entityId, in: context)
	}

	func saveConfigurations() {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.save(in: context)
	}

	func allConfigurations() -> [DeepConfiguration] {
		let context = appState.dataController.container.viewContext
		return DeepConfiguration.getAll(in: context)
	}

	// Handlers:
	private var context: NSManagedObjectContext {
		appState.dataController.container.viewContext
	}
	private var deepConfigurationsChanges: AnyCancellable?

	private func observeDeepConfigurationChanges() {
		deepConfigurationsChanges = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
			.sink { [weak self] notification in
				self?.handleContextChanges(notification)
			}
	}

	private func handleContextChanges(_ notification: Notification) {
		guard let userInfo = notification.userInfo else { return }

		let insertedObjects = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in insertedObjects.compactMap({ $0 as? DeepConfiguration }) {
			do {
				if config.enabled, config.entityId.isNotNil {
					guard let driver = try createDriver(from: config) else {
						assert(false, "Driver has not been initialised after a configuratoin insert.")
						return
					}

					let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
						$0.id() == config.entityId
					}

					assert(isDriverForThisConfigurationLoaded.not, "You are trying to insert a configuration with an UUID that already exist." )

					register(driver: driver, along: config.modelTypeInternal)
				}
			}
			catch {
				deepStateError = error
			}
			//else: The configuration is going to be updated yet.
		}

		let updatedObjects = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in updatedObjects.compactMap({ $0 as? DeepConfiguration }) {
			do {
				guard config.entityId.isNotNil else {
					assert(false, "The confuration should have a valid id already.")
					continue
				}
				let isDriverForThisConfigurationLoaded = (drivers.detectors + drivers.classificators).contains {
					$0.id() == config.entityId
				}
				if isDriverForThisConfigurationLoaded.not, config.enabled {
					guard let driver = try createDriver(from: config) else {
						assert(false, "Driver has not been initialised after a configuratoin insert.")
						return
					}
					register(driver: driver, along: config.modelTypeInternal)
				} else {
					if config.enabled {
						updaterDriver(with: config)
					} else {
						unregisterDriver(with: config)
					}

				}
			}
			catch {
				deepStateError = error
			}
		}

		let deletedObjects = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
		for config in deletedObjects.compactMap({ $0 as? DeepConfiguration }) {
			unregisterDriver(with: config)

			// Delete the model file:
			let fileManager = FileManager.default
			guard let configurationId = config.entityId?.uuidString else {
				print("Can not reconstruct the path to the configuration's directory.")
				return

			}

			let documentDirectory = FileManager.default.documentDirectory
			guard
				let configurationDirectory = documentDirectory?
					.appendingPathComponent("Configurations")
					.appendingPathComponent(configurationId)
					.path(percentEncoded: false),
				fileManager.fileExists(atPath: configurationDirectory)
			else {
				print("There is no filepath, or the file does not exist.")
				return
			}

			guard config.demo.not else { 
				// DO NOT DELETE THE MODEL that is part of the demo
				return
			}
			do {
				try fileManager.removeItem(atPath: configurationDirectory)
				print("File successfully deleted")
			} catch {
				assert(false, "Error deleting file: \(error.localizedDescription)")
			}
		}
	}
}

extension DeepConfiguration: CoreDataManageable {
}

// The class definition (public class DeepConfiguration) is generated from the Core data
extension DeepConfiguration {
	private static var dateFormatter: DateFormatter {
		let formater = DateFormatter()
		formater.dateStyle = .long
		return formater
	}

	public static var rootDirectory: FileManager.SearchPathDirectory {
		get { .documentDirectory }
	}

	public var file: URL? {
		get {
			guard let file_ else { return nil}

			if demo.enabled {
				return Bundle.main.url(forResource: file_.deletingPathExtension().lastPathComponent,
					withExtension: file_.pathExtension)
			} else {
				return try? file_.completePath(to: DeepConfiguration.rootDirectory, isDirectory: false)
			}
		}
	}

	public var annotationColor: Color {
		get {
			guard
				let colorData = annotationColor_,
				let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) else {
				return Color.clear
			}
			return Color(color)
		}
		set {
			let color = UIColor(newValue)
			annotationColor_ = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
		}
	}

	public var selectedSymbol: AnnotationSymbol {
		get {
			AnnotationSymbol(rawValue: selectedSymbol_ ?? "Circle") ?? .circle
		}
		set {
			selectedSymbol_ = newValue.rawValue
		}
	}

	public var creationDate: String {
		return Self.dateFormatter.string(from: creationDate_ ?? .now)
	}

	public var modelTypeInternal: DeepDriverType {
		return DeepDriverType(rawValue: modelType ?? "detect") ?? .detector
	}

	static func == (lhs: DeepConfiguration, rhs: DeepConfiguration) -> Bool {
		return 
			lhs.entityId == rhs.entityId &&
			lhs.file == rhs.file &&
			lhs.modelDescription == rhs.modelDescription &&
			lhs.modelType == rhs.modelType &&
			lhs.author == rhs.author &&
			lhs.creationDate == rhs.creationDate &&
			lhs.annotationColor == rhs.annotationColor &&
			lhs.phaseOutTime == rhs.phaseOutTime &&
			lhs.selectedSymbol == rhs.selectedSymbol &&
			lhs.enabled == rhs.enabled
	}
}

// Add the validations using the core data's api:
extension DeepConfiguration {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		try validateDeepConfiguration()
	}

	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try validateDeepConfiguration()
	}

	private func validateDeepConfiguration() throws {
		if file.isNil || file?.absoluteString.isEmpty == true {
			throw validationError(forKey: "file", error: "Model's file is required.")
		}
		if modelType.isEmptyOrNil == true {
			throw validationError(forKey: "modelType", error: "Model's modelType is required.")
		}
		if annotationColor_.isNil == true {
			throw validationError(forKey: "annotationColor_", error: "Model's annotationColor_ is required.")
		}
		if phaseOutTime < 0.2 {
			throw validationError(forKey: "phaseOutTime", error: "Model's phaseOutTime is required to be >= 0.")
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw validationError(forKey: "entityId", error: "Model's entityId is required.")
		}
	}

	private func validationError(forKey key: String, error: String) -> NSError {
		// TODO: add the error codes
		return NSError(domain: "DeepConfiguration", code: 1000, userInfo: [
			NSLocalizedDescriptionKey: "Validation error - \(key): \(error)"
		])
	}
}

class Guide: ObservableObject {
	unowned var appState: AppState
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var presentSettings: Bool = false
	@Published var pageToOpen: URL?
	@Published var addressBarMenu: [URL] = []
	@Published var addressSelected: URL?

	init(appState: AppState) {
		self.appState = appState
	}

	func togglingSideMenu() {
		presentedSideMenu.toggle()
	}
	
	func ontheflyDetectionResetTapped() {
		if ontheflyDetectionEnabled {
			appState.snap.stopTimer()
			appState.snap.startTimer()
		}
	}

	func historySelected(_ item: URL) {
		addressSelected = item
		addressBarMenu = []
	}

	func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			appState.snap.startTimer()
		} else {
			appState.snap.stopTimer()
		}
	}

	func settingsTapped() {
		presentSettings = true
	}

	func resetApplication() {
		if appState.guide.ontheflyDetectionEnabled {
			appState.guide.ontheflyDetectionTapped()
		}
		appState.deep.reset()
		appState.settings.reset()
		appState.settings.applicationResetButtonToggle.toggle()
		self.appState.deleteBrowsingHistory()
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self else { return }
			self.appState.createDemoEntities()
		}
	}
}

import Combine
class SnapState: ObservableObject {
	unowned var appState: AppState
	var timerCancellable: Cancellable?
	let snapshotTrigger = PassthroughSubject<Void, Never>()
	let timerTrigger = PassthroughSubject<Void, Never>()
	var delayedTimer: Bool = false

	init(appState: AppState) {
		self.appState = appState
	}

	var combinedPublishers: AnyPublisher<Void, Never> {
		Publishers.Merge(timerTrigger, snapshotTrigger)
			.eraseToAnyPublisher()
	}

	func startTimer() {
		guard timerCancellable.isNil else { return }

			// Start the timer and handle its events by sending them to timerTrigger
		self.timerTrigger.send() // start immediately
		timerCancellable = Timer.publish(every: appState.settings.snapFrequency, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				self?.timerTrigger.send()
			}
	}

	func stopTimer() {
		timerCancellable?.cancel()
		timerCancellable = nil
	}
}

protocol DefaultRenderable {
	var defaultRenderer: DefaultRenderer { get }
}

import Vision
// Default renderer for the SwiftUI components
class DefaultRenderer: ObservableObject {
	unowned var appState: AppState

	init(appState: AppState) {
		self.appState = appState
	}

	@MainActor func render<Content>(_ content: Content, completionHandler: @escaping (UIImage?, Error?) -> Void) where Content: View {
		@Environment(\.displayScale) var displayScale
		let renderer = ImageRenderer(content: content)
		renderer.scale = displayScale
		renderer.isOpaque = false
		if let image = renderer.uiImage {
			completionHandler(image, nil)
		} else {
			completionHandler(nil, nil) //TODO: error handling
		}
	}
}

protocol WebViewRenderable {
	var webViewRenderer: WebViewRenderer { get }
}

import WebKit
// Webview renderer for the components with a nested WebView
class WebViewRenderer: DefaultRenderer {
	var webView: WKWebView?

	@MainActor override func render<Content>(_ content: Content, completionHandler: @escaping (UIImage?, Error?) -> Void) where Content: View {
		guard let webView = webView else {
			completionHandler(nil, nil) // TODO: error handling
			return
		}

		let config = WKSnapshotConfiguration()
		webView.takeSnapshot(with: config) { [weak self] image, error in
			guard let self else {
				assert(false, "Renderer exist longer than his parents.")
				return
			}
			if let image = image {
				// The takeSnapshot func does not take in account the changes in the SwiftUI
				// api (brightness, contrast, saturation) and has to be explicitly set here:
				let updatedImage = image.adjusted(brightness: appState.snapAdjustment.brightness,
												 contrast: appState.snapAdjustment.contrast,
												 saturation: appState.snapAdjustment.saturation)
				completionHandler(updatedImage, error)
			} else {
				completionHandler(nil, error)
			}
		}
	}
}

import CoreData
class DataController: ObservableObject {
	static let containerName = "MLBrowser"
	unowned var appState: AppState
	private(set) var container = NSPersistentContainer(name: containerName)

	init(appState: AppState) {
		self.appState = appState
		container.loadPersistentStores { description, error in
			if let error = error {
				print("Core Data failed to load: \(error.localizedDescription)")
				assert(false)
			}
		}
	}
}

//enum CoreDataManageableStatus {
//	case created
//	case updated
//	case deleted
//}

protocol CoreDataManageable where Self: NSManagedObject {
	var entityId: UUID? { get }
	static func create(in context: NSManagedObjectContext) -> Self
	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void)
	static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool)
	static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
	static func delete(_ entity: Self, in context: NSManagedObjectContext)
	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self?
	static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
	// TODO: pull some repeated lines out
	static func create(in context: NSManagedObjectContext) -> Self {
		return Self(context: context)
	}

	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				assert(objects?.count == 1, "The numbner of instances should be one.")
				let objectToUpdate = objects?.first
				if let objectToUpdate {
					updateClosure(objectToUpdate)
					Self.save(in: context)
				}
			} catch {
				assert(false, "Update error: \(error)")
			}
		}
	}

	static func save(in context: NSManagedObjectContext) {
		if context.hasChanges {
			do {
				try context.save()
			} catch let error as NSError {
				print("CoreData save error: \(error)")
					// objects, that are not valid, do not save
			}
		}
	}

	static func delete(_ entity: Self, in context: NSManagedObjectContext) {
		context.delete(entity)
		do {
			try context.save()
		}
		catch let error {
			print("Error deleting a single entity: \(error)")
		}
	}

	static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool = false) {
		let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Self.fetchRequest()
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

		do {
			if executeAndMerge.enabled {
				try context.executeAndMergeChanges(using: deleteRequest)
			} else {
				try context.execute(deleteRequest)
			}

			try context.save()
		} catch let error as NSError {
			print("Error deleting all entities: \(error), \(error.userInfo)")
		}
	}

	static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		context.performAndWait {
			do {
				let objects = try context.fetch(request) as? [Self]
				assert(objects?.count == 1, "The numbner of instances should be one.")
				let objectToDelete = objects?.first
				if let objectToDelete {
					context.delete(objectToDelete)
					Self.save(in: context)
				}
			} catch {
				assert(false, "Deletion error: \(error)")
			}
		}
	}

	static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

		do {
			let objects = try context.fetch(request) as? [Self]
			assert(objects?.count == 1, "The numbner of instances should be one.")
			return objects?.first
		} catch {
			assert(false, "Error fetching object: \(error)")
			return nil
		}
	}

	static func getAll(in context: NSManagedObjectContext) -> [Self] {
		let request = Self.fetchRequest()

		do {
			let objects = try context.fetch(request) as? [Self]
			return objects ?? []
		} catch {
			assert(false, "Error fetching all objects: \(error)")
			return []
		}
	}
}

extension WebHistoryEntry: CoreDataManageable {
// TODO: there are multiple issues with relationships in SwiftUI
//	public var tagsArray: [Tag] {
//		guard let tags else {
//			return []
//		}
//		return Array(_immutableCocoaArray: tags)
//	}
}

extension WebHistoryEntry {
	public override func validateForInsert() throws {
		try super.validateForInsert()
		try validateCommon()
	}

	public override func validateForUpdate() throws {
		try super.validateForUpdate()
		try validateCommon()
	}

	private func validateCommon() throws {
		guard entityId != nil else {
			throw ValidationError.entityIdNil
		}

		guard creationDate_ != nil else {
			throw ValidationError.creationDateNil
		}

		guard let pageURL = page, UIApplication.shared.canOpenURL(pageURL) else {
			throw ValidationError.invalidPageURL
		}
	}
}

extension WebHistoryEntry: Comparable {
	public static func < (lhs: WebHistoryEntry, rhs: WebHistoryEntry) -> Bool {
		switch (lhs.creationDate_, rhs.creationDate_) {
			case (let date1?, let date2?):
				return date1 < date2
			case (nil, _):
				return true
			default:
				return false
		}
	}
}

extension WebHistoryEntry {
	enum ValidationError: LocalizedError {
		case entityIdNil
		case creationDateNil
		case invalidPageURL

		var errorDescription: String? {
			switch self {
				case .entityIdNil:
					return "Entity ID is nil."
				case .creationDateNil:
					return "Creation date is nil."
				case .invalidPageURL:
					return "Invalid page URL."
			}
		}
	}
}
