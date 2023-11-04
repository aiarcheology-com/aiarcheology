//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI

struct SnapshotRendererKey: EnvironmentKey {
	static let defaultValue: ((UIImage) -> Void)? = nil
}

extension EnvironmentValues {
	var snapshotRenderer: ((UIImage) -> Void)? {
		get { self[SnapshotRendererKey.self] }
		set { self[SnapshotRendererKey.self] = newValue }
	}
}

struct SnapableGroup<Content: View, P>: View where P : Publisher, P.Failure == Never {
	@Environment(\.snapshotRenderer) private var snapshotRenderer
	@Environment(\.displayScale) var displayScale
	private let publisher: P
	let content: Content

	@inlinable init(publisher: P, @ViewBuilder content: () -> Content) where P : Publisher, P.Failure == Never {
		self.content = content()
		self.publisher = publisher
	}

	var body: some View {
		content
		.onReceive(publisher) { output in
			let renderer = ImageRenderer(content: content)
			renderer.scale = displayScale
			if let uiImage = renderer.uiImage, let snapshotRenderer {
				snapshotRenderer(uiImage)
			}
		}
	}
}

import Combine
extension View {
	func onSnapshot(perform action: @escaping (UIImage) -> Void) -> some View {
		environment(\.snapshotRenderer, { image in
				action(image)
		})
	}
}

//import Combine
//extension View {
//	func onSnapshot<P>(_ publisher: P, perform action: @escaping (UIImage) -> Void) -> some View where P : Publisher, P.Failure == Never {
//		environment(\.snapshotRenderer, { image in
//			action(image)
//		})
//	}
//}


//import Combine
//extension View {
//	func onSnapshot<P>(_ publisher: P, perform action: @escaping (UIImage) -> Void) -> some View where P : Publisher, P.Failure == Never {
//		self.onReceive(publisher) { _ in
//			Task { @MainActor in
//				let renderer = ImageRenderer(content: self)
//				if let uiImage = renderer.uiImage {
//					action(uiImage)
//				}
//			}
//		}
//	}
//}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
	var deepDrivers = DeepDrivers()
	
	@State var tabbarSelection: AppMode = .web

    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }

    @State var shouldCapture: Bool = false
    @State var selectedSideMenuTab = 0


    var body: some View {
        ZStack {
            TabView(selection: $appState.guide.mode) {
				ForEach(AppMode.tabOrder) { mode in
					ViewContainer( {
						Screens.content(mode)
							.onSnapshot { image in
								deepDrivers.detect(on: image) { observations in
									// pass the observation prbbly into the model
								}
							}
							.annotation(observations) { position // that should be a position in the SnapableGroup
								// create here the UI like with
								// DetectionOverlayView(observations: observations)
							}
							.environmentObject(appState)
					},
					leadingItems: {
						Screens.barItems(mode, position: .leading)
							.environmentObject(appState.guide)
					},
					trailingItems: {
						Screens.barItems(mode, position: .trailing)
							.environmentObject(appState.guide)
					})
					.tabItem {
						Screens.tabItem(mode, selection: tabbarSelection)
					}
					.tag(mode)
				}
            }
			SideMenu {
				SideMenuView(selectedSideMenuTab: $selectedSideMenuTab)
					.onChange(of: selectedSideMenuTab) { newValue in
						shouldCapture = true
					}
			}
			.environmentObject(appState.guide)
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
