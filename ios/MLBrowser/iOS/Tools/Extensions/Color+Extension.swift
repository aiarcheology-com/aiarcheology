//
//  Color+Extension.swift
//  MLBrowser
//
//  Created by Vladimír Cortes Slavík on 06.01.26.
//

import SwiftUI
import UIKit

extension Color {
	/// Creates an sRGB color from 0...255 RGB components and an opacity value.
	/// - Parameters:
	///   - red: Red component in the 0...255 range. Values outside the range are clamped.
	///   - green: Green component in the 0...255 range. Values outside the range are clamped.
	///   - blue: Blue component in the 0...255 range. Values outside the range are clamped.
	///   - opacity: Opacity in the 0.0...1.0 range. Values outside the range are clamped.
	init(red: Int, green: Int, blue: Int, opacity: Double = 1.0) {
		let redComponent = Double(min(max(red, 0), 255)) / 255.0
		let greenComponent = Double(min(max(green, 0), 255)) / 255.0
		let blueComponent = Double(min(max(blue, 0), 255)) / 255.0
		let alphaComponent = min(max(opacity, 0.0), 1.0)
		self = Color(.sRGB, red: redComponent, green: greenComponent, blue: blueComponent, opacity: alphaComponent)
	}
	
	/// Returns a random sRGB color.
	/// Uses UIColor internally for proper Core Data compatibility.
	/// - Parameters:
	///   - opacity: Opacity value in the 0.0...1.0 range. Values outside the range are clamped.
	///   - range: The range from which RGB component values are randomly selected. Default is 0.0...1.0 for full spectrum colors. Use a narrower range (e.g., 0.0...0.5) for darker colors.
	static func random(opacity: Double = 1.0, range: ClosedRange<CGFloat> = 0.0...1.0) -> Color {
		Color(UIColor.random(alpha: opacity, range: range))
	}
}

extension UIColor {
	/// Returns a random sRGB color.
	/// - Parameters:
	///   - alpha: Alpha (opacity) value in the 0.0...1.0 range. Values outside the range are clamped.
	///   - range: The range from which RGB component values are randomly selected. Default is 0.0...1.0 for full spectrum colors. Use a narrower range (e.g., 0.0...0.5) for darker colors.
	static func random(alpha: CGFloat = 1.0, range: ClosedRange<CGFloat> = 0.0...1.0) -> UIColor {
		UIColor(
			red: CGFloat.random(in: range),
			green: CGFloat.random(in: range),
			blue: CGFloat.random(in: range),
			alpha: min(max(alpha, 0), 1)
		)
	}
}
