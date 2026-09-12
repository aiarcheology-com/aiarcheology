//
//  TiledDetectionSettingsView.swift
//  AI Archeology
//
//  Created for AIA-0426.
//

import SwiftUI

/// Settings submenu under "Tiled Detection" that selects which tiling scheme(s) feed the detector.
/// Pyramid and 3x3 are independent (AIA-0426): enable either, both (the union of their regions), or
/// neither (the detector then runs the full frame only).
struct TiledDetectionSettingsView: View {
	@EnvironmentObject var settings: Settings

	var body: some View {
		Form {
			Section(footer: Text(L10n.Settings.tiledDetectionFooter)) {
				Toggle(isOn: $settings.pyramidTiling) {
					HStack {
						Text(L10n.Settings.pyramidTiling)
						Spacer(minLength: 12)
						TilingSchemeIcon(style: .pyramid)
					}
				}
				.testability(Testability.Toggle.settingsPyramidTiling)
				Toggle(isOn: $settings.grid3x3Tiling) {
					HStack {
						Text(L10n.Settings.grid3x3Tiling)
						Spacer(minLength: 12)
						TilingSchemeIcon(style: .grid3x3)
					}
				}
				.testability(Testability.Toggle.settingsGrid3x3Tiling)
			}
			Section(footer: Text(L10n.Settings.tiledBordersFooter)) {
				Toggle(L10n.Settings.tiledBorders, isOn: $settings.tiledBorders)
					.testability(Testability.Toggle.settingsTiledBorders)
			}
		}
		.navigationTitle(L10n.Settings.tiledDetection)
	}
}

/// A small vector preview of a tiling scheme, shown at the trailing edge of its toggle row
/// (AIA-0426). Drawn in SwiftUI rather than shipped as an SVG/PDF asset so it tints with the
/// system secondary-label color — a subordinate accessory that still adapts to and keeps
/// contrast in both light and dark — stays crisp at any Dynamic Type size, and mirrors
/// `TileLayout`'s regions.
private struct TilingSchemeIcon: View {
	enum Style { case pyramid, grid3x3 }
	let style: Style

	@ScaledMetric private var side: CGFloat = 22

	var body: some View {
		TilingSchemeGlyph(style: style)
			.stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
			.frame(width: side, height: side)
			.accessibilityHidden(true)
	}
}

/// Vector glyph mirroring `TileLayout` (AIA-0426): pyramid = a centre cross (the 4 quadrants)
/// plus the centred 50% region; 3x3 = a 3×3 grid. Both carry the outer full-frame border every
/// scheme runs.
private struct TilingSchemeGlyph: Shape {
	let style: TilingSchemeIcon.Style

	func path(in rect: CGRect) -> Path {
		// Inset by half the stroke width so the outer border stays inside the frame.
		let bounds = rect.insetBy(dx: 1, dy: 1)
		var path = Path()
		path.addRect(bounds)
		switch style {
		case .pyramid:
			path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
			path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
			path.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
			path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
			path.addRect(bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25))
		case .grid3x3:
			for i in 1..<3 {
				let x = bounds.minX + bounds.width * CGFloat(i) / 3
				path.move(to: CGPoint(x: x, y: bounds.minY))
				path.addLine(to: CGPoint(x: x, y: bounds.maxY))
				let y = bounds.minY + bounds.height * CGFloat(i) / 3
				path.move(to: CGPoint(x: bounds.minX, y: y))
				path.addLine(to: CGPoint(x: bounds.maxX, y: y))
			}
		}
		return path
	}
}

#Preview {
	NavigationStack {
		TiledDetectionSettingsView()
			.environmentObject(Settings())
	}
}
