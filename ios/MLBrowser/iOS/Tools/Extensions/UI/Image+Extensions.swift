//
//  Image+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 30.11.23.
//

import Foundation

import SwiftUI
extension Image {
    init(templateName: String) {
        if let uiImage = UIImage(named: templateName)?.withRenderingMode(.alwaysTemplate) {
            self.init(uiImage: uiImage)
        } else {
            #if DEBUG
            preconditionFailure("Template image '\(templateName)' not found in asset catalog")
            #else
            // Fallback to system icon in release builds to avoid crashes
            self.init(systemName: "questionmark.square")
            #endif
        }
    }
}
