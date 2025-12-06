//
//  ObservationCircleView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Vision

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
				.blur(radius: animate ? 3 : 0)
				.onAppear {
					withAnimation(.easeInOut(duration: phaseOutTime)) {
						animate = true
					}
				}
		}
	}
}
