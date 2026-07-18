//
//  NativeModelGraphPackage.swift
//  NativeModelConverter
//
//  Integrity-checked reader for the Python-exported .aiagraph package.
//

import CryptoKit
import Foundation

/// The versioned manifest stored at the root of an `.aiagraph` directory.
public struct NativeModelGraphPackageManifest: Codable, Equatable, Sendable {
	public static let formatIdentifier = "com.aiarcheology.native-model-graph"

	public let format: String
	public let formatVersion: Int
	public let graph: String
	/// Optional so packages from an earlier exporter (which pinned only the weights) still load. When
	/// present it is verified; when absent the reader computes it from the graph bytes so provenance
	/// and content identity remain complete.
	public let graphSHA256: String?
	public let weights: String
	public let weightsSHA256: String
	public let metadata: String?
	public let metadataSHA256: String?

	public init(
		formatVersion: Int,
		graphSHA256: String,
		weightsSHA256: String,
		metadataSHA256: String? = nil
	) {
		format = Self.formatIdentifier
		self.formatVersion = formatVersion
		graph = "graph.json"
		self.graphSHA256 = graphSHA256
		weights = "weights.bin"
		self.weightsSHA256 = weightsSHA256
		metadata = metadataSHA256 == nil ? nil : "metadata.json"
		self.metadataSHA256 = metadataSHA256
	}
}

/// A native graph and the immutable weights bytes verified against its package manifest.
public struct NativeModelGraphPackage: Sendable {
	public let manifest: NativeModelGraphPackageManifest
	public let graph: NativeModelGraph
	public let weights: Data
	public let metadata: NativeModelMetadataDocument?
	/// Exact source metadata bytes, retained for the output sidecar without re-encoding unknown fields.
	public let rawMetadata: Data?
	/// Exact input file sizes measured while reading this verified package.
	public let sourceFootprint: NativeModelPackageFootprint

	public init(
		manifest: NativeModelGraphPackageManifest,
		graph: NativeModelGraph,
		weights: Data,
		metadata: NativeModelMetadataDocument? = nil,
		rawMetadata: Data? = nil,
		sourceFootprint: NativeModelPackageFootprint? = nil
	) {
		self.manifest = manifest
		self.graph = graph
		self.weights = weights
		self.metadata = metadata
		self.rawMetadata = rawMetadata
		self.sourceFootprint = sourceFootprint ?? NativeModelPackageFootprint(
			manifestByteCount: 0,
			graphByteCount: 0,
			weightsByteCount: UInt64(weights.count),
			metadataByteCount: UInt64(rawMetadata?.count ?? 0)
		)
	}
}

/// Explicit limits applied before model data is decoded or retained in memory.
public struct NativeModelGraphPackageLimits: Equatable, Sendable {
	public static let `default` = Self(
		maximumManifestBytes: 64 * 1_024,
		maximumGraphBytes: 4 * 1_024 * 1_024,
		maximumWeightsBytes: 512 * 1_024 * 1_024,
		maximumMetadataBytes: 4 * 1_024 * 1_024
	)

	public let maximumManifestBytes: UInt64
	public let maximumGraphBytes: UInt64
	public let maximumWeightsBytes: UInt64
	public let maximumMetadataBytes: UInt64

	public init(
		maximumManifestBytes: UInt64,
		maximumGraphBytes: UInt64,
		maximumWeightsBytes: UInt64,
		maximumMetadataBytes: UInt64 = 4 * 1_024 * 1_024
	) {
		self.maximumManifestBytes = maximumManifestBytes
		self.maximumGraphBytes = maximumGraphBytes
		self.maximumWeightsBytes = maximumWeightsBytes
		self.maximumMetadataBytes = maximumMetadataBytes
	}
}

/// Reads an `.aiagraph` directory without allowing its manifest to select arbitrary paths.
///
/// The reader verifies the whole graph and weights files before an emitter can inspect them. A
/// valid graph can still contain an operation that a particular emitter version does not implement; that later,
/// separate failure is intentional so the interchange contract remains forward-compatible.
public actor NativeModelGraphPackageReader {

	public init(limits: NativeModelGraphPackageLimits = .default) {
		self.limits = limits
	}

	public func read(
		from packageURL: URL,
		reporting progress: NativeModelConversionProgressHandler? = nil,
		checkingCancellation cancellationCheck: NativeModelConversionCancellationHandler? = nil
	) throws -> NativeModelGraphPackage {
		try cancellationCheck?()
		progress?(NativeModelConversionProgress(phase: .readingManifest))
		try rejectIfSymbolicLink(packageURL)
		guard isDirectory(packageURL) else {
			throw NativeModelGraphPackageError.notDirectory(packageURL.lastPathComponent)
		}

		let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
		let manifestData = try readRegularFile(
			at: manifestURL,
			maximumByteCount: limits.maximumManifestBytes,
			logicalName: "manifest.json"
		)
		let manifest: NativeModelGraphPackageManifest
		do {
			manifest = try JSONDecoder().decode(NativeModelGraphPackageManifest.self, from: manifestData)
		} catch let DecodingError.keyNotFound(key, _) {
			throw NativeModelGraphPackageError.invalidManifest("manifest.json is missing required field '\(key.stringValue)'")
		} catch {
			throw NativeModelGraphPackageError.invalidManifest("manifest.json is not valid JSON: \(error.localizedDescription)")
		}
		progress?(NativeModelConversionProgress(phase: .readingManifest, completedUnitCount: 1, totalUnitCount: 1))
		try cancellationCheck?()
		try validate(manifest)
		try validatePackageContents(packageURL, manifest: manifest)
		progress?(NativeModelConversionProgress(phase: .validatingManifest, completedUnitCount: 1, totalUnitCount: 1))

		try cancellationCheck?()
		progress?(NativeModelConversionProgress(phase: .readingGraph))
		let graphData = try readRegularFile(
			at: packageURL.appendingPathComponent(manifest.graph, isDirectory: false),
			maximumByteCount: limits.maximumGraphBytes,
			logicalName: manifest.graph
		)
		let actualGraphChecksum = checksum(of: graphData)
		if let expectedGraphChecksum = manifest.graphSHA256, actualGraphChecksum != expectedGraphChecksum {
			throw NativeModelGraphPackageError.graphChecksumMismatch(
				expected: expectedGraphChecksum,
				actual: actualGraphChecksum
			)
		}
		progress?(NativeModelConversionProgress(phase: .readingGraph, completedUnitCount: 1, totalUnitCount: 1))
		try cancellationCheck?()
		let graph: NativeModelGraph
		do {
			graph = try JSONDecoder().decode(NativeModelGraph.self, from: graphData)
		} catch {
			throw NativeModelGraphPackageError.invalidGraphJSON(error.localizedDescription)
		}
		let graphValidation = NativeModelGraphValidator().validate(graph)
		guard graphValidation.isConvertible else {
			throw NativeModelGraphPackageError.invalidGraph(graphValidation.issues)
		}
		progress?(NativeModelConversionProgress(phase: .validatingGraph, completedUnitCount: 1, totalUnitCount: 1))

		try cancellationCheck?()
		progress?(NativeModelConversionProgress(phase: .readingWeights))
		let weights = try readRegularFile(
			at: packageURL.appendingPathComponent(manifest.weights, isDirectory: false),
			maximumByteCount: limits.maximumWeightsBytes,
			logicalName: manifest.weights
		)
		let actualChecksum = checksum(of: weights)
		guard actualChecksum == manifest.weightsSHA256 else {
			throw NativeModelGraphPackageError.weightsChecksumMismatch(
				expected: manifest.weightsSHA256,
				actual: actualChecksum
			)
		}

		let requiredWeightsByteCount = requiredWeightsByteCount(for: graph)
		guard requiredWeightsByteCount <= UInt64(weights.count) else {
			throw NativeModelGraphPackageError.truncatedWeights(
				requiredByteCount: requiredWeightsByteCount,
				actualByteCount: UInt64(weights.count)
			)
		}
		progress?(NativeModelConversionProgress(phase: .readingWeights, completedUnitCount: 1, totalUnitCount: 1))
		try cancellationCheck?()
		progress?(NativeModelConversionProgress(phase: .validatingWeights, completedUnitCount: 1, totalUnitCount: 1))

		let rawMetadata: Data?
		let metadata: NativeModelMetadataDocument?
		if let metadataFile = manifest.metadata, let expectedMetadataChecksum = manifest.metadataSHA256 {
			try cancellationCheck?()
			progress?(NativeModelConversionProgress(phase: .readingMetadata))
			let metadataData = try readRegularFile(
				at: packageURL.appendingPathComponent(metadataFile, isDirectory: false),
				maximumByteCount: limits.maximumMetadataBytes,
				logicalName: metadataFile
			)
			let actualMetadataChecksum = checksum(of: metadataData)
			guard actualMetadataChecksum == expectedMetadataChecksum else {
				throw NativeModelGraphPackageError.metadataChecksumMismatch(
					expected: expectedMetadataChecksum,
					actual: actualMetadataChecksum
				)
			}
			do {
				metadata = try JSONDecoder().decode(NativeModelMetadataDocument.self, from: metadataData)
			} catch {
				throw NativeModelGraphPackageError.invalidMetadataJSON(error.localizedDescription)
			}
			guard metadata?.format == NativeModelMetadataDocument.formatIdentifier,
				metadata?.formatVersion == NativeModelMetadataDocument.currentFormatVersion
			else {
				throw NativeModelGraphPackageError.invalidMetadataJSON("unsupported metadata format or formatVersion")
			}
			rawMetadata = metadataData
			progress?(NativeModelConversionProgress(phase: .readingMetadata, completedUnitCount: 1, totalUnitCount: 1))
			try cancellationCheck?()
			progress?(NativeModelConversionProgress(phase: .validatingMetadata, completedUnitCount: 1, totalUnitCount: 1))
		} else {
			rawMetadata = nil
			metadata = nil
			progress?(NativeModelConversionProgress(phase: .readingMetadata, completedUnitCount: 1, totalUnitCount: 1))
			progress?(NativeModelConversionProgress(phase: .validatingMetadata, completedUnitCount: 1, totalUnitCount: 1))
		}

		// Store the verified/computed graph checksum so downstream provenance always has it, even for
		// a legacy manifest that pinned only the weights.
		let verifiedManifest = NativeModelGraphPackageManifest(
			formatVersion: manifest.formatVersion,
			graphSHA256: actualGraphChecksum,
			weightsSHA256: manifest.weightsSHA256,
			metadataSHA256: manifest.metadataSHA256
		)
		return NativeModelGraphPackage(
			manifest: verifiedManifest,
			graph: graph,
			weights: weights,
			metadata: metadata,
			rawMetadata: rawMetadata,
			sourceFootprint: NativeModelPackageFootprint(
				manifestByteCount: UInt64(manifestData.count),
				graphByteCount: UInt64(graphData.count),
				weightsByteCount: UInt64(weights.count),
				metadataByteCount: UInt64(rawMetadata?.count ?? 0)
			)
		)
	}

	private let limits: NativeModelGraphPackageLimits

	/// Rejects a symbolic-link package root. `attributesOfItem` uses lstat semantics, so only the
	/// final path component is inspected; symlinked parents (e.g. macOS `/var`) do not trip it.
	private func rejectIfSymbolicLink(_ url: URL) throws {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
			throw NativeModelGraphPackageError.symbolicLinkNotAllowed(url.lastPathComponent)
		}
	}

	private func isDirectory(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

	private func readRegularFile(at url: URL, maximumByteCount: UInt64, logicalName: String) throws -> Data {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw NativeModelGraphPackageError.missingFile(logicalName)
		}
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		let fileType = attributes[.type] as? FileAttributeType
		guard fileType != .typeSymbolicLink else {
			throw NativeModelGraphPackageError.symbolicLinkNotAllowed(logicalName)
		}
		// Reject FIFOs, sockets, and device special files: reading one with `Data(contentsOf:)` can
		// block indefinitely or misbehave. Only a plain regular file is a valid package entry.
		guard fileType == .typeRegular else {
			throw NativeModelGraphPackageError.notRegularFile(logicalName)
		}
		guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
			throw NativeModelGraphPackageError.invalidFileMetadata(logicalName)
		}
		guard size <= maximumByteCount else {
			throw NativeModelGraphPackageError.fileTooLarge(
				file: logicalName,
				actualByteCount: size,
				maximumByteCount: maximumByteCount
			)
		}
		return try Data(contentsOf: url, options: .mappedIfSafe)
	}

	private func validate(_ manifest: NativeModelGraphPackageManifest) throws {
		guard manifest.format == NativeModelGraphPackageManifest.formatIdentifier else {
			throw NativeModelGraphPackageError.invalidManifest("unsupported format '\(manifest.format)'")
		}
		guard manifest.formatVersion == NativeModelGraph.currentFormatVersion else {
			throw NativeModelGraphPackageError.invalidManifest(
				"unsupported formatVersion \(manifest.formatVersion); expected \(NativeModelGraph.currentFormatVersion)"
			)
		}
		guard manifest.graph == "graph.json", manifest.weights == "weights.bin" else {
			throw NativeModelGraphPackageError.invalidManifest(
				"graph and weights files must be named graph.json and weights.bin"
			)
		}
		if let graphSHA256 = manifest.graphSHA256, !isSHA256(graphSHA256) {
			throw NativeModelGraphPackageError.invalidManifest("graphSHA256 must be a lowercase 64-character SHA-256 digest")
		}
		guard isSHA256(manifest.weightsSHA256) else {
			throw NativeModelGraphPackageError.invalidManifest("weightsSHA256 must be a lowercase 64-character SHA-256 digest")
		}
		switch (manifest.metadata, manifest.metadataSHA256) {
		case (nil, nil):
			break
		case ("metadata.json", let checksum?) where isSHA256(checksum):
			break
		default:
			throw NativeModelGraphPackageError.invalidManifest("metadata and metadataSHA256 must either both be absent or name metadata.json with a lowercase SHA-256 digest")
		}
	}

	private func validatePackageContents(
		_ packageURL: URL,
		manifest: NativeModelGraphPackageManifest
	) throws {
		var allowedNames: Set<String> = ["manifest.json", manifest.graph, manifest.weights]
		if let metadata = manifest.metadata {
			allowedNames.insert(metadata)
		}
		for url in try FileManager.default.contentsOfDirectory(
			at: packageURL,
			includingPropertiesForKeys: nil,
			options: []
		) {
			guard allowedNames.contains(url.lastPathComponent) else {
				throw NativeModelGraphPackageError.unexpectedFile(url.lastPathComponent)
			}
		}
	}

	private func checksum(of data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private func isSHA256(_ value: String) -> Bool {
		value.utf8.count == 64 && value.utf8.allSatisfy { byte in
			(48...57).contains(byte) || (97...102).contains(byte)
		}
	}

	private func requiredWeightsByteCount(for graph: NativeModelGraph) -> UInt64 {
		graph.weights.reduce(0) { currentMaximum, weight in
			let (end, overflow) = weight.offset.addingReportingOverflow(weight.byteCount)
			// The graph validator already rejects an overflowing weight range; saturating here keeps
			// this defence-in-depth path from trapping if it is ever reached with an unvalidated graph.
			return overflow ? .max : max(currentMaximum, end)
		}
	}
}

public enum NativeModelGraphPackageError: Error, Equatable, LocalizedError, Sendable {
	case notDirectory(String)
	case missingFile(String)
	case symbolicLinkNotAllowed(String)
	case notRegularFile(String)
	case invalidFileMetadata(String)
	case fileTooLarge(file: String, actualByteCount: UInt64, maximumByteCount: UInt64)
	case invalidManifest(String)
	case unexpectedFile(String)
	case invalidGraphJSON(String)
	case invalidGraph([NativeModelGraphValidationIssue])
	case graphChecksumMismatch(expected: String, actual: String)
	case weightsChecksumMismatch(expected: String, actual: String)
	case metadataChecksumMismatch(expected: String, actual: String)
	case invalidMetadataJSON(String)
	case truncatedWeights(requiredByteCount: UInt64, actualByteCount: UInt64)

	public var errorDescription: String? {
		switch self {
		case .notDirectory(let name):
			"Native model package '\(name)' is not a directory."
		case .missingFile(let name):
			"Native model package is missing '\(name)'."
		case .symbolicLinkNotAllowed(let name):
			"Native model package file '\(name)' must not be a symbolic link."
		case .notRegularFile(let name):
			"Native model package entry '\(name)' must be a regular file."
		case .invalidFileMetadata(let name):
			"Native model package file '\(name)' has invalid metadata."
		case .fileTooLarge(let file, let actualByteCount, let maximumByteCount):
			"Native model package file '\(file)' has \(actualByteCount) bytes; the limit is \(maximumByteCount)."
		case .invalidManifest(let reason):
			"Native model package manifest is invalid: \(reason)."
		case .unexpectedFile(let name):
			"Native model package contains unexpected file '\(name)'."
		case .invalidGraphJSON(let reason):
			"Native model graph JSON is invalid: \(reason)."
		case .invalidGraph(let issues):
			"Native model graph is invalid: \(issues.map(\.localizedDescription).joined(separator: "; "))."
		case .graphChecksumMismatch(let expected, let actual):
			"Native model graph checksum mismatch: expected \(expected), got \(actual)."
		case .weightsChecksumMismatch(let expected, let actual):
			"Native model weights checksum mismatch: expected \(expected), got \(actual)."
		case .metadataChecksumMismatch(let expected, let actual):
			"Native model metadata checksum mismatch: expected \(expected), got \(actual)."
		case .invalidMetadataJSON(let reason):
			"Native model metadata JSON is invalid: \(reason)."
		case .truncatedWeights(let requiredByteCount, let actualByteCount):
			"Native model graph requires \(requiredByteCount) weight bytes, but weights.bin has \(actualByteCount)."
		}
	}
}
