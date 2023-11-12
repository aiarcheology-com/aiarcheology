//
//  EnvironmentObject+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 12.11.23.
//

import Foundation

import SwiftUI
extension EnvironmentObject {
	var hasValue: Bool {
		!String(describing: self).contains("_store: nil")
	}
}
