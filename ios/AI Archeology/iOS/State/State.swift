//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation

enum AppMode: Int, Codable, Hashable {
    case web
    case gallery
    case cloud
    case camera
	// case stream
	// case api
}

class AppState: ObservableObject {
    var guide = Guide()
}

class Guide: ObservableObject {
    @Published var mode = AppMode.web
    @Published private var presentedSideMenu = false

    func togglingSideMenu() {
        presentedSideMenu.toggle()
    }
}

