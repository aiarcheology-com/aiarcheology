//
//  ObservationCircleView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct ObservationCircleView: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIdentifiers: Bool
	var animateDetections: Bool

	@State private var phasedOut = false

	var body: some View {
		let center = boundingBoxCenter
		// The marker first, the label second (AIA-0765). The order used to be the other way round,
		// so the expanding circle was drawn *over* the text — a second reason classes read as
		// invisible, on top of the label content itself being unreadable.
		ZStack {
			pulsingCircle(at: center)
			if showIdentifiers {
				label(at: center)
			}
		}
		.detectionPhaseOut($phasedOut, after: phaseOutTime, animated: animateDetections)
	}

	/// Center of the observation's bounding box in the view's coordinate space
	/// (Vision's bottom-left origin flipped to UIKit's top-left).
	private var boundingBoxCenter: CGPoint {
		let boundingBox = observation.boundingBox
		return CGPoint(
			x: boundingBox.midX * geometry.size.width,
			y: (1 - boundingBox.midY) * geometry.size.height
		)
	}

	/// The detection's single highest-confidence class, centred on the marker — the placement the
	/// ticket asks for on the round symbols (AIA-0765).
	@ViewBuilder
	private func label(at center: CGPoint) -> some View {
		if let primary = observation.primaryLabel {
			DetectionLabelView(identifier: primary.identifier, confidence: observation.confidence, color: color)
				.position(center)
				// Leaves with the marker. Stopping detection does not tear the annotation views down —
				// the phase-out *is* how a detection leaves the screen — so a label that does not read
				// `phasedOut` stays painted over the page after its circle has gone, forever.
				.opacity(phasedOut ? 0 : 1)
		}
	}

	private func pulsingCircle(at center: CGPoint) -> some View {
		let lineWidth: CGFloat = phasedOut ? 6 : 2
		let scale: CGFloat = phasedOut ? 4 : 1
		let circleOpacity: Double = phasedOut ? 0 : 1
		let blurRadius: CGFloat = phasedOut ? 3 : 0
		return Circle()
			.stroke(color, lineWidth: lineWidth)
			.scaleEffect(scale)
			.opacity(circleOpacity)
			.frame(width: 30, height: 30)
			.position(center)
			.blur(radius: blurRadius)
	}
}
