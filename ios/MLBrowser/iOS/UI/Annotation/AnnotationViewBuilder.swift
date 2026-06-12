//
//  AnnotationViewBuilder.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct AnnotationViewBuilder: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var params: DeepDriverParams
	var showIndentifiers: Bool
	/// Present only on screens that support saving findings; without it no hit
	/// area exists and every touch falls through to the content below.
	var onTap: (() -> Void)?

	/// The symbol views fade to opacity 0 (un-hit-testable) over `phaseOutTime`;
	/// this separate window ends the explicit hit area at the same moment, so an
	/// invisible annotation never silently swallows taps/pans meant for the page.
	@State private var tapWindowOpen = true

    var body: some View {
        ZStack {
            switch params.selectedSymbol {
            case .circle:
                ObservationCircleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
            case .square:
                ObservationRectangleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
            case .point:
                ObservationPointView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIndentifiers: showIndentifiers)
            }
            if let onTap, tapWindowOpen {
                tapTarget(action: onTap)
            }
        }
    }

	/// A sized clear hit area over the bounding box. The symbol views themselves are
	/// not tappable: clear fills and faded strokes have no hittable pixels. Known
	/// trade-off: a pan STARTING inside a visible box is claimed by this layer and
	/// won't scroll the page (boxes are small; capture is the primary intent there).
	private func tapTarget(action: @escaping () -> Void) -> some View {
		let rect = observation.viewRect(in: geometry.size)
		return Color.clear
			.frame(width: max(rect.width, 44), height: max(rect.height, 44))
			.position(x: rect.midX, y: rect.midY)
			.contentShape(Rectangle())
			.onTapGesture(perform: action)
			.task {
				// Mirrors the symbol's fade duration; new detections arrive as new
				// view identities (uuid-keyed ForEach), restarting the window.
				try? await Task.sleep(for: .seconds(params.phaseOutTime))
				tapWindowOpen = false
			}
			.accessibilityLabel(observation.primaryLabelIdentifier ?? L10n.Finding.detection)
			.testability(Testability.Button.annotationDetection)
	}
}

extension DetectedObject {
	/// View-space rect for the Vision-normalized full-image bounding box.
	func viewRect(in size: CGSize) -> CGRect {
		boundingBox.visionRect(in: size)
	}
}

extension CGRect {
	/// Interprets self as a Vision-normalized rect (bottom-left origin) and maps it
	/// into a top-left-origin space of the given size — view points or image pixels.
	/// Shared by the live annotations' hit areas, the save-sheet/detail highlight,
	/// and the inventory's thumbnail crop so the transforms cannot drift.
	func visionRect(in size: CGSize) -> CGRect {
		CGRect(
			x: minX * size.width,
			y: (1 - maxY) * size.height,
			width: width * size.width,
			height: height * size.height
		)
	}
}
