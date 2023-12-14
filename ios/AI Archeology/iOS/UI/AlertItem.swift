//
//  AlertItem.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct AlertItem: Identifiable {
	var id = UUID()
	var title: Text
	var message: Text?
	var primaryButton: Alert.Button?
	var dismissButton: Alert.Button?
	var secondaryButton: Alert.Button?
}
