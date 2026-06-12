//
//  AnnotationViewBuilder.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Vision

struct AnnotationViewBuilder: View {
	var observation: DetectedObject
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
