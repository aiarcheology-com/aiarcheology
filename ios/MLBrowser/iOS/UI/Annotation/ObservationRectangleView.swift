//
//  ObservationRectangleView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct ObservationRectangleView: View {
	var observation: DetectedObject
	var geometry: GeometryProxy
	var color: Color
	var phaseOutTime: CFTimeInterval
	var showIdentifiers: Bool
	var animateDetections: Bool

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
			if showIdentifiers {
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
				.opacity(animate ? 0 : 0.5)
				.frame(width: size.width, height: size.height)
				.position(center)
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
}
