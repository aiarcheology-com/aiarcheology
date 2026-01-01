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
            self.init(systemName: "questionmark.square")
        }
    }
}
