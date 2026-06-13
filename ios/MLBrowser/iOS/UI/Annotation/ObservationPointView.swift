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

	@State private var animate = false

	var body: some View {
		let boundingBox = observation.boundingBox
		let circleSize: CGFloat = 60
		let center = CGPoint(x: boundingBox.midX * geometry.size.width,
							 y: (1 - boundingBox.midY) * geometry.size.height)
		ZStack {
			if showIdentifiers {
				HStack {
					ForEach(observation.labels, id: \.self) { label in
						Text(" \(String(label.identifier.prefix(6)))|") // TODO: put this number in the annotation settings
					}
					.foregroundColor(color)
				}
				.position(center)
			}

			Circle()
				.fill(color)
				.frame(width: animate ? circleSize * 1.5 : circleSize, height: animate ? circleSize * 1.5 : circleSize)
				.opacity(animate ? 0 : 0.5)
				.position(center)
				.onAppear {
					withAnimation(.easeInOut(duration: phaseOutTime)) {
						animate = true
					}
				}
		}
	}
}
