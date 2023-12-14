//
//  SideMenu.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 21.09.23.
//

import SwiftUI
import CoreData

enum SideMenuRowType: Int, CaseIterable{
    case home = 0
    case favorite
    case chat
    case profile

    var title: String{
        switch self {
        case .home:
            return "Fortification detection"
        case .favorite:
            return "Fortification detection"
        case .chat:
            return "Enclosure detection"
        case .profile:
            return "Mound dection"
        }
    }

    var iconName: String{
        switch self {
        case .home:
            return "home"
        case .favorite:
            return "favorite"
        case .chat:
            return "chat"
        case .profile:
            return "profile"
        }
    }
}

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



