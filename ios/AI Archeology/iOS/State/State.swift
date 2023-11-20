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
    case cloud
    case camera
	// case stream
	// case api
	static var tabOrder: [AppMode] { [.web, .gallery, .cloud, .camera] }
}

class AppState: ObservableObject {
	lazy var guide = Guide(appState: self)
	lazy var snap = SnapState(appState: self)
	lazy var renderer = DefaultRenderer(appState: self)
	lazy var webViewRenderer = WebViewRenderer(appState: self)
	lazy var deep = DeepState(appState: self)
	lazy var dataController = DataController(appState: self)
}

import Vision
import SwiftUI
class DeepState: ObservableObject {
	unowned private var appState: AppState
	var frame: CGRect = .zero
	@Published var detectedObservations: [VNRecognizedObjectObservation] = []
	@Published var classifiedObservations: [VNClassificationObservation] = []
	@FetchRequest(sortDescriptors: []) var configurations: FetchedResults<DeepConfiguration>
	@Published var newConfiguration: DeepConfiguration?

	init(appState: AppState) {
		self.appState = appState
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
}

extension DeepConfiguration: CoreDataManageable {
}

// The class definition (public class DeepConfiguration) is generated from the Core data
extension DeepConfiguration {
	private static let dateFormatter = DateFormatter()

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

	public var creationDate: String {
		return Self.dateFormatter.string(from: creationDate_ ?? .now)
	}

	static func == (lhs: DeepConfiguration, rhs: DeepConfiguration) -> Bool {
		return 
			lhs.entityId == rhs.entityId &&
			lhs.fileName == rhs.fileName &&
			lhs.modelName == rhs.modelName &&
			lhs.modelType == rhs.modelType &&
			lhs.authorName == rhs.authorName &&
			lhs.creationDate == rhs.creationDate &&
			lhs.annotationColor == rhs.annotationColor &&
			lhs.phaseOutTime == rhs.phaseOutTime &&
			lhs.selectedSymbol == rhs.selectedSymbol &&
			lhs.enabled == rhs.enabled
	}
}

class Guide: ObservableObject {
	unowned private var appState: AppState
	@Published var mode = AppMode.web
	@Published var presentedSideMenu: Bool = false
	@Published var ontheflyDetectionEnabled: Bool = false
	@Published var selectedSideMenuTab: Int = 0

	init(appState: AppState) {
		self.appState = appState
	}

    func togglingSideMenu() {
        presentedSideMenu.toggle()
    }

	func ontheflyDetectionTapped() {
		ontheflyDetectionEnabled.toggle()
		if ontheflyDetectionEnabled {
			appState.snap.startTimer()
		} else {
			appState.snap.stopTimer()
		}
	}
}

import Combine
class SnapState: ObservableObject {
	unowned private var appState: AppState
	var timerCancellable: Cancellable?
	let snapshotTrigger = PassthroughSubject<Void, Never>()
	let timerTrigger = PassthroughSubject<Void, Never>()

	init(appState: AppState) {
		self.appState = appState
	}

	var combinedPublishers: AnyPublisher<Void, Never> {
		Publishers.Merge(timerTrigger, snapshotTrigger)
			.eraseToAnyPublisher()
	}

	func startTimer() {
			// Start the timer and handle its events by sending them to timerTrigger
		timerCancellable = Timer.publish(every: 3, on: .main, in: .common)
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
	unowned private var appState: AppState
	let container = NSPersistentContainer(name: "MLBrowser")

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


protocol CoreDataManageable where Self: NSManagedObject {
	var entityId: UUID? { get }
	static func create(in context: NSManagedObjectContext) -> Self
	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void)
	static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
	static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
	static func create(in context: NSManagedObjectContext) -> Self {
		return Self(context: context)
	}

	static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: (Self) -> Void) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "entityId == '\(entityId)'")

		context.performAndWait {
			do {
				let objectToUpdate = (try context.fetch(request) as? [Self])?.first
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
			} catch {
				assert(false, "CoreData save error: \(error)")
			}
		}
	}

	static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
		let request = Self.fetchRequest()
		request.predicate = NSPredicate(format: "entityId == '\(entityId)'")

		context.performAndWait {
			do {
				let objectToDelete = (try context.fetch(request) as? [Self])?.first
				if let objectToDelete {
					context.delete(objectToDelete)
					Self.save(in: context)
				}
			} catch {
				assert(false, "Deletion error: \(error)")
			}
		}
	}
}
