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
	/// A directly downloadable single-file artifact when the search response exposes one. This lets
	/// the catalog reflect an existing job or imported model without issuing another request.
	let artifactURL: URL?

	init(
		id: String,
		providerId: String,
		displayName: String,
		author: String,
		downloads: Int,
		likes: Int,
		task: CatalogTask,
		format: CatalogArtifactFormat?,
		sizeBytes: Int64?,
		artifactURL: URL? = nil
	) {
		self.id = id
		self.providerId = providerId
		self.displayName = displayName
		self.author = author
		self.downloads = downloads
		self.likes = likes
		self.task = task
		self.format = format
		self.sizeBytes = sizeBytes
		self.artifactURL = artifactURL
	}
}

struct CatalogFile: Codable, Hashable, Sendable {
	let relativePath: String
	let resolveURL: URL
	/// A user-facing location for the artifact. For multi-file packages this is the repository page
	/// for the package directory, rather than the internal `Manifest.json` transfer URL.
	let sourceURL: URL?
	let sizeBytes: Int64?
	/// Optional transport metadata for a file stored on Hugging Face's Xet backend.
	/// Files without this metadata use their ordinary public resolve URL.
	let xetFile: HuggingFaceXetFile?

	init(
		relativePath: String,
		resolveURL: URL,
		sourceURL: URL? = nil,
		sizeBytes: Int64?,
		xetFile: HuggingFaceXetFile? = nil
	) {
		self.relativePath = relativePath
		self.resolveURL = resolveURL
		self.sourceURL = sourceURL
		self.sizeBytes = sizeBytes
		self.xetFile = xetFile
	}
}

extension CatalogFile {
	/// Gives every package the same identity regardless of the order in which a provider returns its
	/// files. A package manifest is its stable primary artifact; ordinary single-file models retain
	/// their own URL as the primary artifact.
	static func orderedForDownload(_ files: [CatalogFile]) -> [CatalogFile] {
		files.sorted { lhs, rhs in
			let lhsIsManifest = lhs.relativePath.lowercased().hasSuffix("/manifest.json")
				|| lhs.relativePath.caseInsensitiveCompare("Manifest.json") == .orderedSame
			let rhsIsManifest = rhs.relativePath.lowercased().hasSuffix("/manifest.json")
				|| rhs.relativePath.caseInsensitiveCompare("Manifest.json") == .orderedSame
			if lhsIsManifest != rhsIsManifest { return lhsIsManifest }
			return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
		}
	}

	static func primaryArtifact(in files: [CatalogFile]) -> CatalogFile? {
		orderedForDownload(files).first
	}
}

struct HuggingFaceXetFile: Codable, Hashable, Sendable {
	let fileID: String
	let tokenURL: URL
	/// The uncompressed artifact size reported by the Hub's file tree.
	let sizeBytes: Int64?
	/// Repository identity required by the official Hugging Face Swift client.
	let repositoryID: String?
	/// Hub endpoint, retained to support test hosts and future enterprise Hub instances.
	let hubURL: URL?

	init(
		fileID: String,
		tokenURL: URL,
		sizeBytes: Int64? = nil,
		repositoryID: String? = nil,
		hubURL: URL? = nil
	) {
		self.fileID = fileID
		self.tokenURL = tokenURL
		self.sizeBytes = sizeBytes
		self.repositoryID = repositoryID
		self.hubURL = hubURL
	}
}

struct CatalogProviderDescriptor: Identifiable, Hashable, Sendable {
	let id: String
	let displayName: String
	/// A source remains visible when its upstream catalog does not currently publish direct Core ML
	/// artifacts, but is not queried or enabled in the source picker.
	let isSearchable: Bool

	init(id: String, displayName: String, isSearchable: Bool = true) {
		self.id = id
		self.displayName = displayName
		self.isSearchable = isSearchable
	}
}

protocol CatalogProvider: Sendable {
	var descriptor: CatalogProviderDescriptor { get }

	func search(query: String) async throws -> [CatalogModel]
	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile]
}

enum CatalogError: Error, Equatable, Sendable {
	case network
	case timedOut
	case invalidResponse
	case decoding
	case noInstallableArtifact
	case tooLarge
	case invalidFilePath
	case tooManyFiles
}
