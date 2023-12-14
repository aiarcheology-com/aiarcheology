//
//  Annotator.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Vision

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
