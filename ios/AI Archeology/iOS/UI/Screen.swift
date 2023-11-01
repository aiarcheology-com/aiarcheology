//
//  Screen.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 31.10.23.
//

import SwiftUI

protocol Screen {
	associatedtype Content: View
	associatedtype BarItems: View
	associatedtype TabItem: View

	static func tabId() -> AppMode

	// Views
	static func content() -> Content
	static func barItems(position: ItemsPosition) -> BarItems
	static func tabItem(selection: AppMode) -> TabItem
}

