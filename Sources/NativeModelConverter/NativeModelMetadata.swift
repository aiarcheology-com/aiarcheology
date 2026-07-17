//
//  NativeModelMetadata.swift
//  NativeModelConverter
//
//  Lossless source metadata carried alongside a native graph package.
//

import Foundation

/// The typed attribution portion of a source metadata document.
///
/// `userDefined` values are strings because Core ML's metadata map is `String` to `String`.
/// Structured values such as labels, preprocessing, and provenance can be canonical JSON strings;
/// the complete original `metadata.json` bytes remain available through
/// ``NativeModelGraphPackage/rawMetadata`` and are written beside the emitted model.
public struct NativeModelCoreMLMetadata: Codable, Equatable, Sendable {
	public let shortDescription: String?
	public let versionString: String?
	public let author: String?
	public let license: String?
	public let userDefined: [String: String]

	public init(
		shortDescription: String? = nil,
		versionString: String? = nil,
		author: String? = nil,
		license: String? = nil,
		userDefined: [String: String] = [:]
	) {
		self.shortDescription = shortDescription
		self.versionString = versionString
		self.author = author
		self.license = license
		self.userDefined = userDefined
	}

	private enum CodingKeys: String, CodingKey {
		case shortDescription
		case versionString
		case author
		case license
		case userDefined
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		shortDescription = try container.decodeIfPresent(String.self, forKey: .shortDescription)
		versionString = try container.decodeIfPresent(String.self, forKey: .versionString)
		author = try container.decodeIfPresent(String.self, forKey: .author)
		license = try container.decodeIfPresent(String.self, forKey: .license)
		userDefined = try container.decodeIfPresent([String: String].self, forKey: .userDefined) ?? [:]
	}
}

/// A versioned envelope around source metadata.
///
/// Exporters put source attribution fields in ``source`` and may add any other JSON fields
/// (for example `labels`, `preprocessing`, `task`, and `provenance`). Unknown fields are preserved
/// byte-for-byte in the package's raw metadata sidecar rather than decoded and re-encoded.
public struct NativeModelMetadataDocument: Codable, Equatable, Sendable {
	public static let formatIdentifier = "com.aiarcheology.native-model-metadata"
	public static let currentFormatVersion = 1

	public let format: String
	public let formatVersion: Int
	public let source: NativeModelCoreMLMetadata

	public init(source: NativeModelCoreMLMetadata) {
		format = Self.formatIdentifier
		formatVersion = Self.currentFormatVersion
		self.source = source
	}
}

/// Host-supplied identity of the source artifact from which a native package was imported.
///
/// The converter always records the package filename when called through the high-level API. A
/// host may additionally supply the original model filename and an authoritative remote URL. Do
/// not supply a local document-provider or sandbox URL: those paths are private to a device and do
/// not describe useful portable model provenance.
public struct NativeModelConversionSourceProvenance: Codable, Equatable, Sendable {
	/// The portable filename of the converted source package, populated by the high-level converter.
	public let sourcePackageFilename: String?
	/// The original model filename before any adapter/export step, when known.
	public let originalModelFilename: String?
	/// The authoritative remote URL for the original model, when one exists.
	public let originalModelURL: String?

	public init(
		sourcePackageFilename: String? = nil,
		originalModelFilename: String? = nil,
		originalModelURL: String? = nil
	) {
		self.sourcePackageFilename = sourcePackageFilename
		self.originalModelFilename = originalModelFilename
		self.originalModelURL = originalModelURL
	}

	func fillingSourcePackageFilename(_ filename: String) -> Self {
		Self(
			sourcePackageFilename: sourcePackageFilename ?? filename,
			originalModelFilename: originalModelFilename,
			originalModelURL: originalModelURL
		)
	}
}

/// Writes the untouched source metadata bytes beside an emitted `.mlmodel`.
///
/// The sidecar is named `<model-name>.metadata.json`, for example
/// `converted.mlmodel` becomes `converted.metadata.json`.
public enum NativeModelMetadataSidecar {
	public static func url(for modelURL: URL) -> URL {
		modelURL.deletingPathExtension().appendingPathExtension("metadata.json")
	}

	public static func write(_ rawMetadata: Data?, beside modelURL: URL) throws {
		let sidecarURL = url(for: modelURL)
		guard let rawMetadata else {
			if FileManager.default.fileExists(atPath: sidecarURL.path) {
				try FileManager.default.removeItem(at: sidecarURL)
			}
			return
		}
		try rawMetadata.write(to: sidecarURL, options: .atomic)
	}
}
