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
import OSLog

// The application does not support the classification yet.
// But the driver can be already loaded, but it does nothing.
actor Classificator: DeepDriver {
    nonisolated let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}

    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
        Logger.drivers.logDebug("Detector initialized with ID \(id)")
    }
    
    func updateConfiguration(_ params: DeepDriverParams) async {
        self.params = params
        Logger.drivers.logDebug("Detector updated with ID \(id)")
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
