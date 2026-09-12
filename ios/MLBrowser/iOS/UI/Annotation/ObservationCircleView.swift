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

	@State private var animate = false

	var body: some View {
		let center = boundingBoxCenter
		ZStack {
			if showIdentifiers {
				labels(at: center)
			}
			pulsingCircle(at: center)
		}
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

	private func labels(at center: CGPoint) -> some View {
		HStack {
			ForEach(observation.labels, id: \.self) { label in
				Text(" \(String(label.identifier.prefix(6)))|")
			}
			.foregroundColor(color)
		}
		.position(center)
	}

	private func pulsingCircle(at center: CGPoint) -> some View {
		let lineWidth: CGFloat = animate ? 6 : 2
		let scale: CGFloat = animate ? 4 : 1
		let circleOpacity: Double = animate ? 0 : 1
		let blurRadius: CGFloat = animate ? 3 : 0
		return Circle()
			.stroke(color, lineWidth: lineWidth)
			.scaleEffect(scale)
			.opacity(circleOpacity)
			.frame(width: 30, height: 30)
			.position(center)
			.blur(radius: blurRadius)
			.onAppear {
				// Static-marker mode (settings.disableDetectionAnimations): leave `animate`
				// at its initial `false` so the marker holds its visible steady state.
				guard animateDetections else { return }
				withAnimation(.easeInOut(duration: phaseOutTime)) {
					animate = true
				}
			}
	}
}
