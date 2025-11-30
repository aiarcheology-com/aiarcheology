//
//  SideMenuCell.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct SideMenuCell: View {
	@EnvironmentObject var configuration: DeepConfiguration

	var body: some View {
		HStack {
			Text(configuration.modelDescription ?? "")
				.testability(Testability.Label.sideMenuCellDescription)
			Spacer()
			Toggle("", isOn: $configuration.enabled)
				.testability(Testability.Toggle.sideMenuCellEnabled)
				.tint(configuration.annotationColor)
				.labelsHidden()
		}
	}
}
