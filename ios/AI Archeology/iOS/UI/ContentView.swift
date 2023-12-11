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
	var observations: [ObservationParams]
	var frame: CGRect?
	var annotationView: (VNRecognizedObjectObservation, DeepDriverParams, CGRect, GeometryProxy) -> AnnotationView

	@ViewBuilder func body(content: Content) -> some View {
		ZStack {
			content
			GeometryReader { geometry in
				ForEach(Array(observations.enumerated()), id: \.offset) { _, observationGroup in
					ForEach(observationGroup.observations, id: \.uuid) { observation in
						if 
							let frame,
							let detection = observation as? VNRecognizedObjectObservation {
							annotationView(detection,
										   observationGroup.params,
										   frame,
										   geometry)
						}
					}
				}
			}
		}
	}
}

extension View {
	func annotate<AnnotationView: View>(from observations: [ObservationParams], withinFrame: CGRect, annotation: @escaping (VNRecognizedObjectObservation, DeepDriverParams, CGRect, GeometryProxy) -> AnnotationView) -> some View {
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
	var showIndentifiers: Bool

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
		let circleSize: CGFloat = 60
		let center = CGPoint(x: boundingBox.midX * geometry.size.width,
							 y: (1 - boundingBox.midY) * geometry.size.height)
		ZStack {
			if showIndentifiers {
				HStack {
					ForEach(observation.labels, id: \.self) { label in
						Text(" \(String(label.identifier.prefix(6)))|") //TODO: put this number in the annotation settings
					}
					.foregroundColor(color)
				}
				.position(center)
			}

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
}

struct ObservationRectangleView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIndentifiers: Bool

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
		let size = CGSize(width: boundingBox.width * geometry.size.width,
						  height: boundingBox.height * geometry.size.height)
		let center = CGPoint(
			x: boundingBox.midX * geometry.size.width,
			y: (1 - boundingBox.midY) * geometry.size.height
		)

		VStack {
			if showIndentifiers {
				HStack {
					ForEach(observation.labels, id: \.self) { label in
						Text(" \(String(label.identifier.prefix(6)))|")
					}
				}
				.foregroundColor(color)
				.frame(width: size.width)
				.offset(x: center.x - geometry.size.width / 2, y: center.y - size.height / 2)
			}
			Rectangle()
				.fill(Color.clear)
				.border(color, width: 4)
				.opacity(animate ? 0 : 0.5) // Animate opacity
				.frame(width: size.width, height: size.height)
				.position(center)
				.onAppear {
					withAnimation(.easeInOut(duration: phaseOutTime)) {
						animate = true
					}
				}
		}
	}
}


struct ObservationCircleView: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIndentifiers: Bool

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
			// Calculate the center of the bounding box
		let center = CGPoint(
			x: boundingBox.midX * geometry.size.width,
			y: (1 - boundingBox.midY) * geometry.size.height
		)

		ZStack {
			if showIndentifiers {
				HStack {
					ForEach(observation.labels, id: \.self) { label in
						Text(" \(String(label.identifier.prefix(6)))|")
					}
					.foregroundColor(color)
				}
				.position(center)
			}
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
}

struct AnnotationViewBuilder: View {
	var observation: VNRecognizedObjectObservation
	var geometry: GeometryProxy
	var params: DeepDriverParams
	var showIndentifiers: Bool

	var body: some View {
		Group {
			switch params.selectedSymbol {
				case .circle:
					ObservationCircleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
				case .square:
					ObservationRectangleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
				case .point:
					ObservationPointView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
			}
		}
	}
}

import Combine
struct ContentView: View {
	// environment:
	@Environment(\.colorScheme) var colorScheme
	@Environment(\.dismiss) var dismiss
	// app model:
    @EnvironmentObject var appState: AppState
	// sheets, alerts and menus:
	@State private var detectedObservations: [ObservationParams] = []
	@State private var showingForm = false
	@State private var showingSettingsForm = false
	@State private var showErrorAlert = false
	@State private var showSlideshow = false
	@State private var addressBarMenu: [URL] = []
	@State private var errorMessage = ""
	// content manipulation:
	@State private var brightness = SnapAdjustment.defaultBrightness
	@State private var contrast = SnapAdjustment.defaultContrast
	@State private var saturation = SnapAdjustment.defaultSaturation

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
							.annotate(from: detectedObservations, withinFrame: appState.deep.frame) { observation, params, parentFrame, geometry  in
								AnnotationViewBuilder(observation: observation, geometry: geometry, params: params, showIndentifiers: appState.settings.showIdentifiers)
							}
							.gesture( // Reset the annoation when we drag the content
								DragGesture()
									.onEnded { _ in
										detectedObservations.removeAll()
									}
							)
							// ---- Apply the image properties to the content -----
						    // Some lidar/map/orto websites have slightly different brightnes
						    // which can be compensated by adjusting one of these properties:
							.onReceive(appState.snapAdjustment.$brightness) { newValue in
								brightness = newValue
							}
							.onReceive(appState.snapAdjustment.$contrast) { newValue in
								contrast = newValue
							}
							.onReceive(appState.snapAdjustment.$saturation) { newValue in
								saturation = newValue
							}
							.brightness(brightness)
							.contrast(contrast)
							.saturation(saturation)
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
				.toolbar(AppMode.tabOrder.count == 1 ? .hidden : .visible, for: .tabBar)
            }
			// ----- Side Menu: -----
			SideMenuLogic(isFirstLaunch: appState.settings.isFirstLaunchMarked) {
				// Plus button triggered: -> create new configuration
				appState.deep.newConfiguration = appState.deep.createConfiguration()
				showingForm = true
			}
			onSelectCell: { entityId in
				// Configuration cell selected: -> open existing configuration
				appState.guide.selectedConfigurationId = entityId
				showingForm = true
			}
			.onReceive(appState.guide.$addressBarMenu) { urls in
				addressBarMenu = urls
			}
			.dropDownMenu(items: addressBarMenu, backgroundColor: colorScheme == .dark ? .black : .white, 
			cancelContent: {
				HStack {
					Spacer()
					Button {
						appState.guide.addressBarMenu = []
					} label: {
						Image(systemName: "xmark.circle.fill")
					}
					.foregroundColor(.gray)
					.padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 25))
				}
			}) { item in
				Button {
					appState.guide.historySelected(item)
				} label: {
					Text(item.absoluteString.trimmedString)
						.foregroundColor(.gray)
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer()
				}
			}
			.environmentObject(appState.guide)
			.environmentObject(appState.deep)
			// ------ Show the slideshow after the app's installation -----
        }
		// ------ Configurations Form -----
		.sheet(isPresented: $showSlideshow) {
			SlideshowView()
				.centerInParentView()
				.environmentObject(appState.settings)
		}
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
		.onReceive(appState.guide.$presentSettings) { present in
			showingSettingsForm = present
		}
		.sheet(isPresented: $showingSettingsForm, onDismiss: {
			showingSettingsForm = false
		}) {
			SettingsForm()
				.environmentObject(appState.settings)
				.environmentObject(appState.guide)
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
		.onAppear { // should be called only once after the app start
			guard appState.snap.delayedTimer.not else { return }

			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				if appState.settings.snapAfterAppStart {
					appState.guide.ontheflyDetectionTapped()
				}
				appState.snap.delayedTimer = true
			}

			if appState.settings.keepSlideShowActive {
				showSlideshow = true
			}
		}
    }
}

struct SideMenuLogic: View {
	var isFirstLaunch: Bool
	var onAddCell: () -> Void //TODO: observe changes using Guide properties
	var onSelectCell: (UUID) -> Void //TODO: observe changes using Guide properties
	@EnvironmentObject var guide: Guide
	@State var selectedConfigurationId: UUID?

	var body: some View {
		SideMenu(presentedSideMenu: $guide.presentedSideMenu) {
			SideMenuView(isFirstLaunch: isFirstLaunch, selectedConfigurationId: $selectedConfigurationId,
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

// Please, Apple, make a real native dropdown menu for textField
struct DropdownMenuModifier<Item, ItemContent: View, CancelContent: View>: ViewModifier where Item: Hashable {
	var backgroundColor: Color = .clear
	var items: [Item]
	var cancelContent: () -> CancelContent
	var itemContent: (Item) -> ItemContent

	func body(content baseContent: Content) -> some View {
		if items.isEmpty {
			baseContent
		} else {
			GeometryReader { geometry in
				ZStack(alignment: .top) {
					baseContent
					VStack {
						Spacer()
						.frame(height: 42)
						.allowsHitTesting(false)
						ScrollView {
							cancelContent()
							VStack(alignment: .leading) {
								ForEach(Array(items.enumerated()), id: \.offset) { index, item in
										itemContent(item)
											.padding(5)
											.transition(.opacity)
								}
							}
							.background(backgroundColor)
						}
						.frame(width: 0.6 * geometry.size.width, height: 0.4 * geometry.size.height)
						.padding(5)
						.background(
							RoundedRectangle(cornerRadius: 5)
							.fill(backgroundColor)
							.overlay(
								RoundedRectangle(cornerRadius: 5)
									.stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
							)
							.shadow(color: .black.opacity(0.75), radius: 5, x: 0, y: 0)
						)
					}
					.animation(.easeInOut, value: items)
				}
			}
		}
	}
}

extension View {
	public func dropDownMenu<Item, CancelContent: View, ItemContent: View>(
															items: [Item],
															backgroundColor: Color,
															@ViewBuilder cancelContent: @escaping () -> CancelContent,
															@ViewBuilder itemContent: @escaping (Item) -> ItemContent)
														-> some View where Item: Hashable {

		modifier(DropdownMenuModifier(backgroundColor: backgroundColor,
									items: items,
									cancelContent: cancelContent,
									itemContent: itemContent)
		)
	}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
