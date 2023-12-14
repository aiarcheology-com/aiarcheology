//
//  AppMode.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

enum AppMode: Int, Codable, Hashable, Identifiable {
	var id: Self { self }
	case web
	case gallery
		// case cloud
		// case camera
		// case stream
		// case api
	static var tabOrder: [AppMode] { [.web] }
}
