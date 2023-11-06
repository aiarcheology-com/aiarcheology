//
//  WebScreen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

struct WebScreen: Screen {
	@ViewBuilder
	static func content() -> some View {
		VStack {
			FirstItem()
		}
	}

	@ViewBuilder
	static func barItems(position: ItemsPosition) -> some View {
		switch position {
			case .leading:
				GlobalToolbarLeading()
			case .trailing:
				GlobalToolbarTrailing()
		}
	}

	static func tabId() -> AppMode {
		.web
	}

	@ViewBuilder
	static func tabItem(selection: AppMode) -> some View {
		if tabId() == selection {
			Image(systemName: "map")
		} else {
			Image(systemName:"map").environment(\.symbolVariants, .none)
		}
		Text("Web")
	}

}

import WebKit
public class TakeScreenShotCommand {
	var screenShot: UIImage?
	func takeScreenShot(_ webview: WKWebView) {
		webview.takeSnapshot(with: nil, completionHandler: { image, error in
			if let image = image {
				self.screenShot = image
			}
		})
	}
}

import Vision
struct FirstItem: View {

	let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	@StateObject var viewModel = TextViewModel()
		//    var websiteUrl: CurrentValueSubject<String, Never> = .init("")
	@State private var websiteUrl: String = "https://ags.cuzk.cz/av/?extent=-831332.9688214378,-1117345.0500381005,-639820.6497967998,-1016468.2402844809&zvd=dmr5g&rf=GrayscaleHillshade&o=0"
	@State private var isWebsiteLoading: Bool = false
	@State private var inputUrl: String = ""

		//    @Binding var shouldCapture: Bool
		//    @State var capturedImage: UIImage?
		// Initialize the object detector
	let objectDetector = ObjectDetector()
	// let screenShotCommand = TakeScreenShotCommand()

	@State private var observations: [VNRecognizedObjectObservation] = []

	var body: some View {
			// probably there should be a common impl for all capturable tabs.
			// Each capturable tab should have its own impl of image capture and maybe later also a detection
			SnapableGroup(publisher: timer) {
				AntWebView(websiteUrl, observations: observations, /*shouldCapture: $shouldCapture,*/ capturedImageChanged: { image in
					if /*shouldCapture*/ true == true {
							// Trigger object detection
						objectDetector.detectObjects(in: image) { newObservations  in
							if let newObservations {
								self.observations = newObservations
							}
								// shouldCapture = false // Reset the flag
						}
					}
				}) { loading, error in
					print("loading status : \(loading)")
				}
			}
			.navigationBarTitle("", displayMode: .inline)
			.clipped()
			.toolbar {
				ToolbarItem(placement: .principal) {
						// TODO: change the url in the text field,
						// when it is updated in the webview component
						// maybe move to some model...
					TextField("website url", text: $inputUrl)
						.textFieldStyle(.roundedBorder)
						.textInputAutocapitalization(.never)
						.disableAutocorrection(true)
						.onSubmit(of: .text, {
							self.websiteUrl = inputUrl
						})
				}
			}
		.gesture(
			DragGesture()
				.onEnded { _ in
					observations.removeAll()
				}
		)
	}
}
