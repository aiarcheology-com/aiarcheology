//
//  FileManager+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import Foundation

extension FileManager {
	static func deepConfigurationDirectory(id: UUID) -> URL? {
		return FileManager.default.documentDirectory?
				.appendingPathComponent("Configurations")
				.appendingPathComponent(id.uuidString)
	}
}
