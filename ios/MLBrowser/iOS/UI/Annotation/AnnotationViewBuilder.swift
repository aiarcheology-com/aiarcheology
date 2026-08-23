//
//  AnnotationViewBuilder.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

/// Produces the detection results that may be shown or picked. The confidence filter lives before
/// the symbol switch, so rectangle, circle and point presentation share exactly the same set.
enum DetectionPresentation {
	static func filteredFrame(_ frame: AppliedDetectionFrame?) -> AppliedDetectionFrame? {
		guard let frame else { return nil }
		return AppliedDetectionFrame(image: frame.image, results: filteredResults(frame.results))
	}

	static func filteredResults(_ results: [DetectionResult]) -> [DetectionResult] {
		results.compactMap { group in
			let threshold = Float(DeepConfiguration.detectionConfidenceThreshold(for: group.params.entityId))
			let observations = group.observations.filter { $0.confidence >= threshold }
			guard observations.isEmpty.not else { return nil }
			return (observations: observations, params: group.params)
		}
	}
}

struct AnnotationViewBuilder: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var params: DeepDriverParams
	var showIdentifiers: Bool
	var animateDetections: Bool

    var body: some View {
        Group {
            switch params.selectedSymbol {
            case .circle:
                ObservationCircleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
            case .square:
                ObservationRectangleView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
            case .point:
                ObservationPointView(observation: observation, geometry: geometry, color: params.annotationColor, phaseOutTime: params.phaseOutTime, showIdentifiers: showIdentifiers, animateDetections: animateDetections)
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
