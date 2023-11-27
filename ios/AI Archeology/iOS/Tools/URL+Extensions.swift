//
//  URL+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.11.23.
//

import Foundation

extension URL {
	func completePath(to directory: FileManager.SearchPathDirectory) throws -> URL {
		try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false)
		.appendingPathComponent(self.path)
	}

	func relativePath(from directory: FileManager.SearchPathDirectory) throws ->  URL {
		let fileManager = FileManager.default

		guard let directoryURL = try? fileManager.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false) else {
			throw CocoaError(.fileNoSuchFile)
		}

		let directoryPath = directoryURL.path

		guard
			self.path.hasPrefix(directoryPath),
			let urlEncoded = String(self.path.dropFirst(directoryPath.count)).addingPercentEncoding(withAllowedCharacters: .alphanumerics),
			let relativeURL = URL(string: urlEncoded) else {
			throw CocoaError(.fileNoSuchFile)
		}

		return relativeURL
	}
}
