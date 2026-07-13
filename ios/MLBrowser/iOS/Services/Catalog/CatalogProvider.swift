//
//  CatalogProvider.swift
//  AI Archeology
//
//  AIA-0413: provider-neutral model-catalog domain.
//

import Foundation

enum CatalogArtifactFormat: String, Codable, Sendable {
	case mlmodel
	case mlpackage
}

enum CatalogTask: String, Codable, Sendable {
	case objectDetection = "object-detection"
	case imageClassification = "image-classification"
}

struct CatalogModel: Identifiable, Codable, Hashable, Sendable {
	/// The provider's stable repository identifier (for Hugging Face, `author/model`).
	let id: String
	let providerId: String
	let displayName: String
	let author: String
	let downloads: Int
	let likes: Int
	let task: CatalogTask
	/// Search APIs do not always expose repository file trees. `nil` means the format is resolved
	/// when the user selects the result, rather than guessed from tags.
	let format: CatalogArtifactFormat?
	let sizeBytes: Int64?
}

struct CatalogFile: Hashable, Sendable {
	let relativePath: String
	let resolveURL: URL
	let sizeBytes: Int64?
}

struct CatalogProviderDescriptor: Identifiable, Hashable, Sendable {
	let id: String
	let displayName: String
}

protocol CatalogProvider: Sendable {
	var descriptor: CatalogProviderDescriptor { get }

	func search(query: String) async throws -> [CatalogModel]
	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile]
}

enum CatalogError: Error, Equatable, Sendable {
	case network
	case invalidResponse
	case decoding
	case noInstallableArtifact
	case cancelled
	case tooLarge
	case invalidFilePath
	case tooManyFiles
}
