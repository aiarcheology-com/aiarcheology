//
//  Classificator.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import Vision
import SwiftUI
import UIKit

// The application does not support the classification yet.
// But the driver can be already loaded, but it does nothing.
actor Classificator: DeepDriver {
    // Swift 6: Use nonisolated(unsafe) for immutable value types that need cross-isolation access
    // This is safe because UUID is a value type and 'let' ensures immutability after initialization
    nonisolated(unsafe) let id: UUID

	internal var params: DeepDriverParams = DeepDriverParams()
	internal var observations: [VNObservation] = []

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}

	init(configuration: DeepConfiguration, entityId: UUID) {
        self.id = entityId
	}

	func load() async {
	}

	func loadFile() async throws {
	}

	func unload() async {
	}

	func process(image: UIImage) async {
	}

	func classify() async {
			// TODO: TBD
	}

	func run() async {
		await classify()
	}
}
