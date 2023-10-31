//
//  State.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.10.23.
//

import Foundation

enum AppMode: Int, Codable, Hashable, Identifiable {
	var id: Self { self }
    case web
    case gallery
    case cloud
    case camera
	// case stream
	// case api
	static var tabOrder: [AppMode] { [.web, .gallery, .cloud, .camera] }
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

