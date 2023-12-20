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
// But the driver can be already loaded
actor Classificator: DeepDriver {
	internal var params: DeepDriverParams = DeepDriverParams()
	private let internalId: UUID = UUID()
	internal var observations: [VNObservation] = []

	func metadata() -> [MLModelMetadataKey : Any]? {
		[:]
	}

	nonisolated func id() -> UUID? {
		UUID()
	}

	init(configuration: DeepConfiguration, entityId: UUID) throws {
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
