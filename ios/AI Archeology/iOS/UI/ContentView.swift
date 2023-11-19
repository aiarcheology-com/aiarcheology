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
	var snapshotProvider: ((UIImage, CGRect) -> Void)? {
		get { self[SnapshotRendererKey.self] }
		set { self[SnapshotRendererKey.self] = newValue }
	}
}


// Do not forget to initiate a custom renderer, e.g. .environmentObject(customRenderer)
// when wrapping another View
struct SnapableGroup<Content: View, P>: View where P: Publisher, P.Failure == Never {
	@Environment(\.snapshotProvider) private var snapshotProvider
	private unowned var renderer: DefaultRenderer

	private let publisher: P
	private var content: Content

	@inlinable init(renderer: DefaultRenderer, publisher: P, @ViewBuilder content: () -> Content) {
		self.publisher = publisher
		self.content = content()
		self.renderer = renderer
	}

	var body: some View {
		GeometryReader { geometry in
			content
				.onReceive(publisher) { _ in
				render(in: geometry.frame(in: .local))
			}
		}
	}

	@MainActor private func render(in frame: CGRect) {
		renderer.render(content) { image, error in
			if let image = image, error == nil {
				snapshotProvider?(image, frame)
			} else {
					//TODO: Handle error
			}
		}
	}
}

import Combine
extension View {
	// The snapshot is made from a view wrapped within SnapableGroup and driven by the group's publisher
	func onSnapshot(perform action: @escaping (UIImage, CGRect) -> Void) -> some View {
		environment(\.snapshotProvider, { image, frame in
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
				renderer.isOpaque = false
				if let uiImage = renderer.uiImage {
					action(uiImage)
				}
			}
		}
	}
}

struct Annotator<AnnotationView: View>: ViewModifier {
	var detections: [VNRecognizedObjectObservation]
	var frame: CGRect?
	var annotationView: (VNRecognizedObjectObservation, CGRect, GeometryProxy) -> AnnotationView

	@ViewBuilder func body(content: Content) -> some View {
		ZStack {
			content
			GeometryReader { geometry in
				ForEach(detections, id: \.uuid) { detection in
					if let frame {
						annotationView(detection, frame, geometry)
					}
				}
			}
		}
	}
}

extension View {
	func annotate<AnnotationView: View>(from detections: [VNRecognizedObjectObservation], withinFrame: CGRect, annotation: @escaping (VNRecognizedObjectObservation, CGRect, GeometryProxy) -> AnnotationView) -> some View {
		modifier(Annotator(detections: detections, frame: withinFrame, annotationView: annotation))
	}
}

import SwiftUI
import Vision

struct ObservationRectangleView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy

	var body: some View {
		let boundingBox = observation.boundingBox
		let size = CGSize(width: boundingBox.size.width * geometry.size.width, height: boundingBox.size.height * geometry.size.height)
		let position = CGPoint(x: boundingBox.origin.x * geometry.size.width + 80,
							   y: (1 - boundingBox.origin.y - boundingBox.size.height) * geometry.size.height + 80)

		Rectangle()
			.fill(Color.clear)
			.border(Color.red, width: 4)
			.frame(width: size.width, height: size.height)
			.position(x: position.x, y: position.y)
	}
}

import Combine
struct ContentView: View {
    @EnvironmentObject var appState: AppState
	var deepDrivers = DeepDrivers()

	@State private var showingForm = false

    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }

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
							.annotate(from: appState.deep.detectedObservations, withinFrame: appState.deep.frame) { observation, parentFrame, geometry  in
								ObservationRectangleView(observation: observation, geometry: geometry)
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
			SideMenuLogic(showingForm: $showingForm, onAddCell: {
				appState.deep.newConfiguration = DeepConfiguration()
				showingForm = true
			})
			.environmentObject(appState.guide)
			.environmentObject(appState.deep)
        }
		.sheet(isPresented: $showingForm) {
			if let config = appState.deep.newConfiguration {
				ConfigurationForm(isPresented: $showingForm)
					.environmentObject(config)
					.onChange(of: config) { newValue in
						
					}
			} else {
				// TODO: load an existin configuration
			}
		}
    }
}

struct SideMenuLogic: View {
	@Binding var showingForm: Bool
	@State var onAddCell: (() -> Void)
	@EnvironmentObject var guide: Guide
	@EnvironmentObject var deep: DeepState

	var body: some View {
		SideMenu(presentedSideMenu: $guide.presentedSideMenu) {
			SideMenuView(cells: deep.configurations.map { SideMenuData(id: $0.id, title: $0.modelName, enabled: $0.enabled) },
						selectedSideMenuTab: $guide.selectedSideMenuTab,
						presentedSideMenu: $guide.presentedSideMenu,
						onAddCell: onAddCell)
		}
		.onChange(of: guide.selectedSideMenuTab) { newValue in
			showingForm = true
		}
	}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
