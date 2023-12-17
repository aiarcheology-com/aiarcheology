//
//  SideMenu.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 21.09.23.
//

import SwiftUI
import CoreData

class SideMenuData: ObservableObject {
	@Published var id: UUID?
	@Published var title: String?
	@Published var enabled: Bool

	init(id: UUID?, title: String?, enabled: Bool) {
		self.id = id
		self.title = title
		self.enabled = enabled
	}
}



