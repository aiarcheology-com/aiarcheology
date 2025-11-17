//
//  Appearance.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 13.10.23.
//

import SwiftUI

struct Backports {
    struct Appearance {
        @discardableResult
        static func configure() -> Self.Type {
            return Self.self
        }

        @MainActor @discardableResult
        static func tabbar() -> Self.Type {
        #if os(iOS)
            UITabBar.appearance().backgroundColor = .systemBackground
            UITabBar.appearance().unselectedItemTintColor = UIColor.gray
        #elseif os(macOS)

        #endif
            return Self.self
        }
        @MainActor @discardableResult
        static func navigationBar() -> Self.Type {
        #if os(iOS)
            let appearance = UINavigationBarAppearance()
            appearance.backgroundColor = .systemBackground
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        #elseif os(macOS)
                        
        #endif
            return Self.self
        }

        @MainActor @discardableResult
		static func textField() -> Self.Type {
		#if os(iOS)
			UITextField.appearance().clearButtonMode = .whileEditing
		#elseif os(macOS)

		#endif
			return Self.self
		}
    }
}
