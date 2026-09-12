//
//  Color+Extension.swift
//  MLBrowser
//
//  Created by Vladimír Cortes Slavík on 06.01.26.
//

import SwiftUI
import UIKit

extension Color {
	/// Archives to `Data` via `NSKeyedArchiver`-encoded `UIColor` — the single shared
	/// representation for persisted colors (`DeepConfiguration.annotationColor` in Core
	/// Data, `Settings.flashColor` in UserDefaults; AIA-0374 unified the two copies).
	func archivedData() -> Data? {
		try? NSKeyedArchiver.archivedData(withRootObject: UIColor(self), requiringSecureCoding: false)
	}

	/// Decodes a color archived by `archivedData()`; `fallback` on nil/corrupt data.
	static func unarchived(from data: Data?, fallback: Color) -> Color {
		guard
			let data,
			let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
			return fallback
		}
		return Color(color)
	}

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

	/// A random colour vivid enough to mark a detection on a map (AIA-0757).
	///
	/// Detection annotations used to be `random(range: 0.1...0.6)`, which caps every component at
	/// 153/255 — so they could not be vivid *by construction* and trended muddy over hillshade
	/// imagery. See ``UIColor/vividAnnotation()`` for the rule.
	static func vividAnnotation() -> Color {
		Color(UIColor.vividAnnotation())
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

	// MARK: - Vivid annotation colours (AIA-0757)

	/// One component must clear this for the colour to count as vivid.
	///
	/// Strictly *above* 200, as the report words it — a colour whose strongest component landed
	/// exactly on 200 would otherwise fail the very rule that produced it.
	static let vividDominantFloor = 201

	/// At least one component must sit at or below this.
	///
	/// This is what stops "all three high", which is how a random generator produces grey and white.
	/// A low component is also what gives the colour its hue: three similar values have none.
	static let vividShadeCeiling = 150

	/// Perceived luminance must stay inside this band.
	///
	/// The floor keeps a colour off near-black; the ceiling is the one the component rule alone
	/// cannot enforce — `(255, 150, 255)` satisfies "one above 200, one at or below 150" and is still
	/// a pale pink that disappears as a `Toggle` tint on a light drawer and as a stroke over
	/// hillshade relief.
	static let vividLuminanceBand: ClosedRange<CGFloat> = 0.10...0.65

	/// A random colour vivid enough to mark a detection, per the rule reported in AIA-0757:
	/// **at least one component above 200, never all three high.**
	///
	/// Built to satisfy the rule rather than sampling until it happens to: one component is drawn
	/// above the floor, another at or below the ceiling, and the third is free. Only the luminance
	/// band needs rejection, because it is a property of the three together — bounded, with a
	/// deterministic fallback so this always terminates.
	static func vividAnnotation() -> UIColor {
		for _ in 0..<16 {
			let candidate = vividCandidate()
			if vividLuminanceBand.contains(perceivedLuminance(of: candidate)) {
				return uiColor(candidate)
			}
		}
		// Unreachable in practice; a fixed vivid colour beats looping or returning something muddy.
		// One of the two the report itself gives as an example of what it is asking for.
		return uiColor((230, 10, 200))
	}

	/// 0...255 components as an sRGB `UIColor`, matching ``Color/init(red:green:blue:opacity:)``.
	private static func uiColor(_ components: (Int, Int, Int)) -> UIColor {
		let (red, green, blue) = components
		return UIColor(
			red: CGFloat(red) / 255,
			green: CGFloat(green) / 255,
			blue: CGFloat(blue) / 255,
			alpha: 1
		)
	}

	/// One draw satisfying the component rule, before the luminance band is considered.
	private static func vividCandidate() -> (Int, Int, Int) {
		var components = [
			Int.random(in: vividDominantFloor...255),
			Int.random(in: 0...vividShadeCeiling),
			Int.random(in: 0...255)
		]
		components.shuffle()
		return (components[0], components[1], components[2])
	}

	/// Perceived luminance on the 0...1 scale, from gamma-encoded components.
	///
	/// The eye's own weighting, not a colorimetric one: this judges whether a stroke reads on screen,
	/// and green carries most of that impression.
	static func perceivedLuminance(of components: (Int, Int, Int)) -> CGFloat {
		let (red, green, blue) = components
		return (0.299 * CGFloat(red) + 0.587 * CGFloat(green) + 0.114 * CGFloat(blue)) / 255
	}

	/// Whether `components` satisfy the vividness rule. Shared by the generator's own tests so the
	/// rule is stated once.
	static func isVivid(_ components: (Int, Int, Int)) -> Bool {
		let (red, green, blue) = components
		let all = [red, green, blue]
		guard all.contains(where: { $0 >= vividDominantFloor }) else { return false }
		guard all.contains(where: { $0 <= vividShadeCeiling }) else { return false }
		return vividLuminanceBand.contains(perceivedLuminance(of: components))
	}
}
