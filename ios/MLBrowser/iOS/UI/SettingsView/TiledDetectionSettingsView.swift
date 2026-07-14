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
				Toggle(L10n.Settings.pyramidTiling, isOn: $settings.pyramidTiling)
					.testability(Testability.Toggle.settingsPyramidTiling)
				Toggle(L10n.Settings.grid3x3Tiling, isOn: $settings.grid3x3Tiling)
					.testability(Testability.Toggle.settingsGrid3x3Tiling)
			}
		}
		.navigationTitle(L10n.Settings.tiledDetection)
	}
}

#Preview {
	NavigationStack {
		TiledDetectionSettingsView()
			.environmentObject(Settings())
	}
}
