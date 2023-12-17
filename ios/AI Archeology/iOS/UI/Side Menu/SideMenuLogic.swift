//
//  SideMenuLogic.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct SideMenuLogic: View {
	var isFirstLaunch: Bool
	var onAddCell: () -> Void
	var onDownloadTap: () -> Void
	var onSelectCell: (UUID) -> Void
	@EnvironmentObject var guide: Guide
	@State var selectedConfigurationId: UUID?

	var body: some View {
		SideMenu(presentedSideMenu: $guide.presentedSideMenu) {
			SideMenuView(isFirstLaunch: isFirstLaunch, selectedConfigurationId: $selectedConfigurationId,
						 presentedSideMenu: $guide.presentedSideMenu,
						 onAddCell: onAddCell, 
						 onDownloadTap: onDownloadTap)
		}
		.onChange(of: selectedConfigurationId) { newValue in
			guard let newValue else { return }
			selectedConfigurationId = nil
			onSelectCell(newValue)
		}
	}
}
