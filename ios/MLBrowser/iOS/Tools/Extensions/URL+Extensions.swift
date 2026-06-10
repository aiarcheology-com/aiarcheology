//
//  URL+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.11.23.
//

import Foundation

extension URL {
	func completePath(to directory: FileManager.SearchPathDirectory, isDirectory: Bool) throws -> URL {
		let baseDirectoryURL = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false)
		return baseDirectoryURL.appendingPathComponent(self.path, isDirectory: isDirectory)
	}

	func relativePath(from directory: FileManager.SearchPathDirectory) throws -> URL {
		let fileManager = FileManager.default

		guard let directoryURL = try? fileManager.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false) else {
			throw CocoaError(.fileNoSuchFile)
		}

		let directoryPath = directoryURL.path

		guard
			self.path.hasPrefix(directoryPath) else {
			throw CocoaError(.fileNoSuchFile)
		}

		var relativePath = String(self.path.dropFirst(directoryPath.count))
		if relativePath.hasPrefix("/") {
			relativePath.removeFirst()
		}

		// .urlPathAllowed keeps "/" and "." intact; .alphanumerics encoded them
		// ("model.mlmodelc" → "model%2Emlmodelc") and only round-tripped by accident.
		guard let urlEncoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
			throw CocoaError(.fileWriteUnknown)
		}

		guard let relativeURL = URL(string: urlEncoded) else {
			throw CocoaError(.fileNoSuchFile)
		}

		return relativeURL
	}
}
