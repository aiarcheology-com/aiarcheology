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
	var showIdentifiers: Bool

    var body: some View {
        Group {
            switch params.selectedSymbol {
            case .circle:
                ObservationCircleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers)
            case .square:
                ObservationRectangleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers)
            case .point:
                ObservationPointView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers)
            }
        }
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
