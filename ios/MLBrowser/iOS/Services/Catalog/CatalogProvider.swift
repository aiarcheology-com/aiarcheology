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
	/// An ONNX graph that is converted to Core ML on-device at import time.
	case onnx
}

enum CatalogTask: String, Codable, Sendable {
	case objectDetection = "object-detection"
	case imageClassification = "image-classification"
}

/// A coarse model-family tag used purely for catalog display and filtering. It is derived from a
/// model's id/keywords and MUST NOT influence labels, preprocessing, or task semantics
/// (AIA-0497: a URL or name may decide what we *say*, never what we *do*).
enum ModelFamily: String, Codable, Sendable, CaseIterable {
	case mobileNetV2
	case resNet50
	case squeezeNet
	case yolo
}

/// How well a catalog entry is supported on-device. These are structural levels rather than a
/// free-text caveat, so the honesty of each level cannot be silently dropped by a later refactor
/// (AIA-0497).
enum CatalogSupport: String, Codable, Sendable {
	/// A Core ML artifact (`.mlmodel`/`.mlpackage`) that imports directly.
	case coreMLNative
	/// Oracle-verified ONNX with a correct, usable interface (recognizable labels / catalogued head).
	case verifiedConvertible
	/// Oracle-verified box geometry, but the export carries no class names, so it imports with
	/// generic `class_<i>` labels (e.g. metadata-less YOLO exports).
	case verifiedGeometryGenericLabels
	/// Unverified ONNX (e.g. live Hugging Face search): on-device conversion is attempted and may
	/// fail for unsupported operators.
	case convertible
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
	/// A coarse family tag for display and filtering only (see `ModelFamily`). `nil` means the
	/// classifier did not recognise a family — such entries stay visible unless a family filter is
	/// active, where they belong to the explicit "Other" bucket.
	let family: ModelFamily?
	/// How honestly the catalog can promise this entry works on-device (see `CatalogSupport`).
	let support: CatalogSupport

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
		artifactURL: URL? = nil,
		family: ModelFamily? = nil,
		support: CatalogSupport = .coreMLNative
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
		self.family = family
		self.support = support
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

/// Optional, per-model catalog provenance. This is display metadata, not a queryable model field,
/// so it is keyed by the download/configuration UUID in UserDefaults instead of requiring a Core
/// Data schema migration for already-shipped stores.
enum CatalogSourceStore {
	static func source(for id: UUID) -> String? {
		guard let source = UserDefaults.standard.string(forKey: key(for: id)) else { return nil }
		let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmedSource.isEmpty ? nil : trimmedSource
	}

	static func setSource(_ source: String?, for id: UUID) {
		guard let source else {
			removeSource(for: id)
			return
		}
		let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmedSource.isEmpty == false else {
			removeSource(for: id)
			return
		}
		UserDefaults.standard.set(trimmedSource, forKey: key(for: id))
	}

	static func removeSource(for id: UUID) {
		UserDefaults.standard.removeObject(forKey: key(for: id))
	}

	private static func key(for id: UUID) -> String {
		"catalog.source.\(id.uuidString)"
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
