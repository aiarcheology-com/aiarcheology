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
	static var tabOrder: [AppMode] { [.web, .gallery] }
}

class AppState: ObservableObject {
	lazy var guide = Guide(appState: self)
	lazy var snap = SnapState(appState: self)
	lazy var renderer = DefaultRenderer(appState: self)
	lazy var webViewRenderer = WebViewRenderer(appState: self)
	lazy var deep = DeepState(appState: self)
	lazy var dataController = DataController(appState: self)
	lazy var settings = Settings(appState: self)
}

protocol Validatable {
	func validate() throws
}

enum ValidationError: Error {
	case invalidData(String)
}

class Settings: ObservableObject, Validatable {
	unowned private var appState: AppState
	// TODO: add a porperty to reset the app
	private enum UserDefaultsKeys {
		static let snapAfterAppStart = "snapAfterAppStart"
		static let snapFrequency = "snapFrequency"
		static let resetHistory = "resetHistory"
		static let defaultPage = "defaultPage"
		static let removeAnnotationOnDrag = "removeAnnotationOnDrag"
		static let entityId = "entityId"
	}

	@Published public var applicationResetButtonToggle: Bool = false

	@Published public var snapAfterAppStart: Bool {
		didSet {
			UserDefaults.standard.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
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

	@Published public var entityId: UUID? {
		didSet {
			UserDefaults.standard.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		}
	}

	init(appState: AppState) {
		self.appState = appState

		let defaultValues: [String: Any] = [
			UserDefaultsKeys.snapAfterAppStart: false,
			UserDefaultsKeys.snapFrequency: 3.0,
			UserDefaultsKeys.resetHistory: false,
			UserDefaultsKeys.defaultPage: URL(string: "https://www.google.com")!,
			UserDefaultsKeys.removeAnnotationOnDrag: false,
			UserDefaultsKeys.entityId: UUID().uuidString
		]

			// Register default values
		UserDefaults.standard.register(defaults: defaultValues)
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
		self.snapAfterAppStart = false
		self.snapFrequency = 3.0
		self.resetHistory = false
		self.defaultPage = URL(string: "https://www.google.com")
		self.removeAnnotationOnDrag = false
		self.entityId = UUID()  // Generating a new UUID

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
	unowned private var appState: AppState
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

	func reset() {
		let context = appState.dataController.container.viewContext
		for configuration in allConfigurations() {
			context.delete(configuration)
		}
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
			lhs.model == rhs.model &&
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
	unowned private var appState: AppState
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedConfigurationId: UUID?
	@Published var presentSettings: Bool = false

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
	}
}

import Combine
class SnapState: ObservableObject {
	unowned private var appState: AppState
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
	unowned private var appState: AppState

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
		webView.takeSnapshot(with: config) { image, error in
			if let image = image {
				completionHandler(image, error)
			} else {
				completionHandler(nil, error)
			}
		}
	}
}

import CoreData
class DataController: ObservableObject {
	static let containerName = "MLBrowser"
	unowned private var appState: AppState
	private(set) var container = NSPersistentContainer(name: containerName)
	let settingsContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)

	init(appState: AppState) {
		self.appState = appState
		container.loadPersistentStores { description, error in
			if let error = error {
				print("Core Data failed to load: \(error.localizedDescription)")
				assert(false)
			}
		}
		settingsContext.parent = container.viewContext
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
	static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
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
