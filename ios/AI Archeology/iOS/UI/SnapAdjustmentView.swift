//
//  SnapAdjustmentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 30.11.23.
//

import Foundation
import SwiftUI

struct SnapAdjustmentView: View {
	@EnvironmentObject var snapAdjustment: SnapAdjustment

	var body: some View {
		VStack {
			HStack {
				Text("Brightness")
					.font(.footnote)
				Spacer()
				Text("\(snapAdjustment.brightness, specifier: "%.2f")")
					.testability(Testability.Label.snapAdjustmentBrightnessValue)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Slider(value: $snapAdjustment.brightness, in: -1...1, step: 0.01)
				.testability(Testability.Slider.snapAdjustmentBrightness)

			HStack {
				Text("Contrast")
					.font(.footnote)
				Spacer()
				Text("\(snapAdjustment.contrast, specifier: "%.2f")")
					.testability(Testability.Label.snapAdjustmentContrastValue)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Slider(value: $snapAdjustment.contrast, in: 0...5, step: 0.01)
				.testability(Testability.Slider.snapAdjustmentContrast)

			HStack {
				Text("Saturation")
					.font(.footnote)
				Spacer()
				Text("\(snapAdjustment.saturation, specifier: "%.2f")")
					.testability(Testability.Label.snapAdjustmentSaturationValue)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Slider(value: $snapAdjustment.saturation, in: 0...1, step: 0.01)
				.testability(Testability.Slider.snapAdjustmentSaturation)
			HStack {
				Spacer()
				Button("Reset") {
					resetValues()
				}
				.testability(Testability.Button.snapAdjustmentReset)
			}
			.padding(10)

		}
	}

	private func resetValues() {
		snapAdjustment.brightness = SnapAdjustment.defaultBrightness
		snapAdjustment.contrast = SnapAdjustment.defaultContrast
		snapAdjustment.saturation = SnapAdjustment.defaultSaturation
	}
}
