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
	var observations: [(observations: [VNRecognizedObjectObservation], configuration: DeepConfiguration)]
	var frame: CGRect?
	var annotationView: (VNRecognizedObjectObservation, DeepConfiguration, CGRect, GeometryProxy) -> AnnotationView

	@ViewBuilder func body(content: Content) -> some View {
		ZStack {
			content
			GeometryReader { geometry in
				ForEach(Array(observations.enumerated()), id: \.offset) { _, observationGroup in
					ForEach(observationGroup.observations, id: \.uuid) { observation in
						if let frame {
							annotationView(observation, observationGroup.configuration, frame, geometry)
						}
					}
				}
			}
		}
	}
}

extension View {
	func annotate<AnnotationView: View>(from observations: [(observations: [VNRecognizedObjectObservation], configuration: DeepConfiguration)], withinFrame: CGRect, annotation: @escaping (VNRecognizedObjectObservation, DeepConfiguration, CGRect, GeometryProxy) -> AnnotationView) -> some View {
		modifier(Annotator(observations: observations, frame: withinFrame, annotationView: annotation))
	}
}

import SwiftUI
import Vision

struct ObservationPointView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
		let circleSize: CGFloat = 60
		let center = CGPoint(x: boundingBox.midX * geometry.size.width,
							 y: (1 - boundingBox.midY) * geometry.size.height)

		Circle()
			.fill(color)
			.frame(width: animate ? circleSize * 1.5 : circleSize, height: animate ? circleSize * 1.5 : circleSize)
			.opacity(animate ? 0 : 0.5)
			.position(center)
			.onAppear {
				withAnimation(.easeInOut(duration: phaseOutTime)) {
					animate = true
				}
			}
	}
}

struct ObservationRectangleView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
		let size = CGSize(width: boundingBox.size.width * geometry.size.width, height: boundingBox.size.height * geometry.size.height)
		let position = CGPoint(x: boundingBox.origin.x * geometry.size.width + 80,
							   y: (1 - boundingBox.origin.y - boundingBox.size.height) * geometry.size.height + 80)

		Rectangle()
			.fill(Color.clear)
			.border(color, width: 4)
			.opacity(animate ? 0 : 0.5) // Animate opacity
			.frame(width: size.width, height: size.height)
			.position(x: position.x, y: position.y)
			.onAppear {
				withAnimation(.easeInOut(duration: phaseOutTime)) {
					animate = true
				}
			}
	}
}


struct ObservationCircleView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
			// Calculate the center of the bounding box
		let center = CGPoint(
			x: boundingBox.midX * geometry.size.width,
			y: (1 - boundingBox.midY) * geometry.size.height
		)

		Circle()
			.stroke(color, lineWidth: animate ? 6 : 2)
			.scaleEffect(animate ? 4 : 1)
			.opacity(animate ? 0 : 1)
			.frame(width: 30, height: 30)
			.position(center)
			.blur(radius: animate ? 3 : 0) // Apply blur as the circle grows
			.onAppear {
				withAnimation(.easeInOut(duration: phaseOutTime)) {
					animate = true
				}
			}
	}
}

struct AnnotationViewBuilder: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var configuration: DeepConfiguration

	var body: some View {
		Group {
			switch configuration.selectedSymbol {
				case .circle:
					ObservationCircleView(observation: observation, geometry: geometry, color: configuration.annotationColor, phaseOutTime: configuration.phaseOutTime)
				case .square:
					ObservationRectangleView(observation: observation, geometry: geometry, color: configuration.annotationColor, phaseOutTime: configuration.phaseOutTime)
				case .point:
					ObservationPointView(observation: observation, geometry: geometry, color: configuration.annotationColor, phaseOutTime: configuration.phaseOutTime)
			}
		}
	}
}

import Combine
struct ContentView: View {
    @EnvironmentObject var appState: AppState
	@State private var detectedObservations: [(observations: [VNRecognizedObjectObservation], configuration: DeepConfiguration)] = []
	@State private var showingForm = false
	@State private var showErrorAlert = false
	@State private var errorMessage = ""

    init() {
        Backports.Appearance
            .configure()
            .tabbar()
            .navigationBar()
    }

    var body: some View {
        ZStack {
			// ------ Tabs: ------
            TabView(selection: $appState.guide.mode) {
				ForEach(AppMode.tabOrder) { mode in
					ViewContainer( {
						Screens.content(mode)
							.onSnapshot { image, frame in
								appState.deep.drivers.detect(on: image) { observations in
									detectedObservations = observations
									appState.deep.frame = frame
								}
							}
							.annotate(from: detectedObservations, withinFrame: appState.deep.frame) { observation, configuration, parentFrame, geometry  in
								AnnotationViewBuilder(observation: observation, geometry: geometry, configuration: configuration)
							}
							.gesture(
								DragGesture()
									.onEnded { _ in
										detectedObservations.removeAll()
									}
							)
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
			// ----- Side Menu: -----
			SideMenuLogic {
				// Plus button triggered: -> create new configuration
				appState.deep.newConfiguration = appState.deep.createConfiguration()
				showingForm = true
			}
			onSelectCell: { entityId in
				// Configuration cell selected: -> open existing configuration
				appState.guide.selectedConfigurationId = entityId
				showingForm = true
			}
			.environmentObject(appState.guide)
			.environmentObject(appState.deep)
        }
		// ------ Configurations Form -----
		.sheet(isPresented: $showingForm, onDismiss: {
			appState.deep.newConfiguration = nil
			appState.guide.selectedConfigurationId = nil
		}) {
			if let config = appState.deep.newConfiguration {
				ConfigurationForm()
					.environmentObject(config)
					.environmentObject(appState.deep)
			} else
			if let selectedConfigurationId = appState.guide.selectedConfigurationId,
			   let config = appState.deep.selectConfiguration(selectedConfigurationId) {
				ConfigurationForm()
					.environmentObject(config)
					.environmentObject(appState.deep)
			}
		}
		// ------ Error processing -----
		.onReceive(appState.deep.$deepStateError) { error in
			guard let error else { return }
			errorMessage = error.localizedDescription
			showErrorAlert = true
		}
		.alert(isPresented: $showErrorAlert) {
			Alert(title: Text("Error"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
		}
    }
}

struct SideMenuLogic: View {
	var onAddCell: () -> Void //TODO: observe changes using Guide properties
	var onSelectCell: (UUID) -> Void //TODO: observe changes using Guide properties
	@EnvironmentObject var guide: Guide
	@State var selectedConfigurationId: UUID?

	var body: some View {
		SideMenu(presentedSideMenu: $guide.presentedSideMenu) {
			SideMenuView(selectedConfigurationId: $selectedConfigurationId,
						presentedSideMenu: $guide.presentedSideMenu,
						onAddCell: onAddCell)
		}
		.onChange(of: selectedConfigurationId) { newValue in
			guard let newValue else { return }
			selectedConfigurationId = nil
			onSelectCell(newValue)
		}
	}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
