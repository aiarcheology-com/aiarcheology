//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI

struct SnapshotRendererKey: EnvironmentKey {
	static let defaultValue: ((UIImage, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
	var snapshotRenderer: ((UIImage, CGRect) -> Void)? {
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
		GeometryReader { geometry in
			content
			.onReceive(publisher) { output in
				let renderer = ImageRenderer(content: content)
				renderer.scale = displayScale
				if let uiImage = renderer.uiImage, let snapshotRenderer {
					snapshotRenderer(uiImage, geometry.frame(in: CoordinateSpace.local)) // TODO:  if this space does not work, use global or named(AnyHashable)
				}
			}
		}
	}
}

import Combine
extension View {
	// The snapshot is made from a view wrapped within SnapableGroup and driven by the group's publisher
	func onSnapshot(perform action: @escaping (UIImage, CGRect) -> Void) -> some View {
		environment(\.snapshotRenderer, { image, frame in
				action(image, frame)
		})
	}
	// The snapshot is made from a complete view and driven by an explicit publisher
	func onSnapshot<P>(_ publisher: P, perform action: @escaping (UIImage) -> Void) -> some View where P : Publisher, P.Failure == Never {
		self.onReceive(publisher) { _ in
			Task { @MainActor in
				@Environment(\.displayScale) var displayScale
				let renderer = ImageRenderer(content: self)
				renderer.scale = displayScale
				if let uiImage = renderer.uiImage {
					action(uiImage)
				}
			}
		}
	}
}

//import Vision
//struct Annotator: ViewModifier {
//	var geometry: GeometryProxy
//	var detectionObservations: [VNRecognizedObjectObservation]
//	var annotation: () -> some View // compiler: Property declares an opaque return type, but has no initializer expression from which to infer an underlying type
//	@ViewBuilder func body(content: Content) -> some View {
//		content
//		annotation
//	}
//}
//
//extension View {
//	func annotate(from detectionObservations: [VNRecognizedObjectObservation], geometry: GeometryProxy) -> some View {
//		modifier(Annotator(geometry: geometry, detectionObservations: detectionObservations, annotation: <#() -> some View#>))
//	}
//}

import SwiftUI
import Vision
//
//struct Annotator: ViewModifier {
//	var detections: [VNRecognizedObjectObservation]
//	var frame: CGRect?
//	var annotationView: (VNRecognizedObjectObservation, CGRect) -> AnyView
//
//	@ViewBuilder func body(content: Content) -> some View {
//		ZStack {
//			content
//			ForEach(detections, id: \.uuid) { detection in
//				if let frame {
//					annotationView(detection, frame)
//						.position(x: frame.origin.x, y: frame.origin.y)
//				}
//			}
//		}
//	}
//}

//extension View {
//	func annotate(from detections: [VNRecognizedObjectObservation], frame: CGRect?, annotation: @escaping (VNRecognizedObjectObservation, CGRect) -> AnyView) -> some View {
//		modifier(Annotator(detections: detections, frame: frame, annotationView: annotation))
//	}
//}


struct Annotator<AnnotationView: View>: ViewModifier {
	var detections: [VNRecognizedObjectObservation]
	var frame: CGRect?
	var annotationView: (VNRecognizedObjectObservation, CGRect) -> AnnotationView

	@ViewBuilder func body(content: Content) -> some View {
		ZStack {
			content
			ForEach(detections, id: \.uuid) { detection in
				if let frame {
					annotationView(detection, frame)
				}
			}
		}
	}
}

extension View {
	func annotate<AnnotationView: View>(from detections: [VNRecognizedObjectObservation], withinFrame: CGRect, annotation: @escaping (VNRecognizedObjectObservation, CGRect) -> AnnotationView) -> some View {
		modifier(Annotator(detections: detections, frame: withinFrame, annotationView: annotation))
	}
}


struct ContentView: View {
    @EnvironmentObject var appState: AppState
	var deepDrivers = DeepDrivers()

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
							.onSnapshot { image, frame in
								deepDrivers.detect(on: image) { observations in
									appState.deep.detectedObservations = observations
									appState.deep.frame = frame
								}
							}
							.annotate(from: appState.deep.detectedObservations, withinFrame: appState.deep.frame) { observation, frame in
								EmptyView() // add a proper annotation
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
						Screens.tabItem(mode, selection: appState.guide.mode)
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
