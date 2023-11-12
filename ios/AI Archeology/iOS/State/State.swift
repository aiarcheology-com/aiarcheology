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
	lazy var deep = DeepState(appState: self)
	lazy var snap = SnapState(appState: self)
	lazy var renderer = DefaultRenderer(appState: self)
	lazy var webViewRenderer = WebViewRenderer(appState: self)
}

import Vision
import SwiftUI
class DeepState: ObservableObject {
	unowned private var appState: AppState
	var frame: CGRect = .zero
	@Published var detectedObservations: [VNRecognizedObjectObservation] = []
	@Published var classifiedObservations: [VNClassificationObservation] = []

	init(appState: AppState) {
		self.appState = appState
	}
}

class Guide: ObservableObject {
	unowned private var appState: AppState
    @Published var mode = AppMode.web
    @Published var presentedSideMenu = false
	@Published var ontheflyDetectionEnabled = false
	
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

//import WebKit
//protocol CustomRenderable {
//	var customRenderer: CustomRenderer { get }
//	func render(completionHandler: @escaping (UIImage?, Error?) -> Void)
//}

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


