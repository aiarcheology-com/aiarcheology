//
//  AppMode.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

enum AppMode: Int, Codable, Hashable, Identifiable, CaseIterable {
	var id: Self { self }
	case web
		// case gallery — removed in AIA-0898; it was never in `tabOrder`, so it never rendered
		// case cloud
		// case camera
		// case stream
		// case api
	static var tabOrder: [AppMode] { [.web] }
}
