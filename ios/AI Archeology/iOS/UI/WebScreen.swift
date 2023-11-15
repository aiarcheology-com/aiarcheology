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
			WebScreenView()
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

import Vision
struct WebScreenView: View {
	@EnvironmentObject var appState: AppState
	@State private var websiteUrl: String = "https://ags.cuzk.cz/av/?extent=-831332.9688214378,-1117345.0500381005,-639820.6497967998,-1016468.2402844809&zvd=dmr5g&rf=GrayscaleHillshade&o=0"
	@State private var isWebsiteLoading: Bool = false
	@State private var inputUrl: String = ""

	var body: some View {
		// Passing appState.webViewRenderer as arg to be able to check, because:
		// https://stackoverflow.com/questions/59822245/swiftui-optional-environment-object
		SnapableGroup(renderer: appState.webViewRenderer, publisher: appState.snap.combinedPublishers) {
			MLWebView(websiteUrl) { loading, error in
					print("loading status : \(loading)")
				}
				.environmentObject(appState.webViewRenderer)
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
	}
}
