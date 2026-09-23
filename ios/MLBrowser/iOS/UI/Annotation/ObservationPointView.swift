//
//  ObservationPointView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct ObservationPointView: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIdentifiers: Bool
	var animateDetections: Bool

	@State private var phasedOut = false

	var body: some View {
		let circleSize: CGFloat = 60
		let center = DetectionViewport.center(ofNormalized: observation.boundingBox, in: geometry.size)
		// Marker first, label second (AIA-0765): the filled 60pt disc used to be drawn on top of the
		// text, which is a large part of why classes were not visible on this symbol.
		ZStack {
			Circle()
				.fill(color)
				.frame(width: phasedOut ? circleSize * 1.5 : circleSize, height: phasedOut ? circleSize * 1.5 : circleSize)
				.opacity(phasedOut ? 0 : 0.5)
				.position(center)

			if showIdentifiers, let primary = observation.primaryLabel {
				DetectionLabelView(identifier: primary.identifier, confidence: observation.confidence, color: color)
					.position(center)
					// Leaves with the marker. Stopping detection does not tear the annotation views
					// down — the phase-out *is* how a detection leaves the screen — so a label that
					// does not read `phasedOut` stays painted over the page after its dot has gone.
					.opacity(phasedOut ? 0 : 1)
			}
		}
		.detectionPhaseOut($phasedOut, after: phaseOutTime, animated: animateDetections)
	}
}
