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
	public let weights: String
	public let weightsSHA256: String

	public init(formatVersion: Int, weightsSHA256: String) {
		format = Self.formatIdentifier
		self.formatVersion = formatVersion
		graph = "graph.json"
		weights = "weights.bin"
		self.weightsSHA256 = weightsSHA256
	}
}

/// A native graph and the immutable weights bytes verified against its package manifest.
public struct NativeModelGraphPackage: Sendable {
	public let manifest: NativeModelGraphPackageManifest
	public let graph: NativeModelGraph
	public let weights: Data

	public init(manifest: NativeModelGraphPackageManifest, graph: NativeModelGraph, weights: Data) {
		self.manifest = manifest
		self.graph = graph
		self.weights = weights
	}
}

/// Explicit limits applied before model data is decoded or retained in memory.
public struct NativeModelGraphPackageLimits: Equatable, Sendable {
	public static let `default` = Self(
		maximumManifestBytes: 64 * 1_024,
		maximumGraphBytes: 4 * 1_024 * 1_024,
		maximumWeightsBytes: 512 * 1_024 * 1_024
	)

	public let maximumManifestBytes: UInt64
	public let maximumGraphBytes: UInt64
	public let maximumWeightsBytes: UInt64

	public init(maximumManifestBytes: UInt64, maximumGraphBytes: UInt64, maximumWeightsBytes: UInt64) {
		self.maximumManifestBytes = maximumManifestBytes
		self.maximumGraphBytes = maximumGraphBytes
		self.maximumWeightsBytes = maximumWeightsBytes
	}
}

/// Reads an `.aiagraph` directory without allowing its manifest to select arbitrary paths.
///
/// The reader verifies the whole weights file before an emitter can inspect it. A valid graph can
/// still contain an operation that a particular emitter version does not implement; that later,
/// separate failure is intentional so the interchange contract remains forward-compatible.
public actor NativeModelGraphPackageReader {

	public init(limits: NativeModelGraphPackageLimits = .default) {
		self.limits = limits
	}

	public func read(from packageURL: URL) throws -> NativeModelGraphPackage {
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
		} catch {
			throw NativeModelGraphPackageError.invalidManifest("manifest.json is not valid JSON: \(error.localizedDescription)")
		}
		try validate(manifest)

		let graphData = try readRegularFile(
			at: packageURL.appendingPathComponent(manifest.graph, isDirectory: false),
			maximumByteCount: limits.maximumGraphBytes,
			logicalName: manifest.graph
		)
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

		return NativeModelGraphPackage(manifest: manifest, graph: graph, weights: weights)
	}

	private let limits: NativeModelGraphPackageLimits

	private func isDirectory(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

	private func readRegularFile(at url: URL, maximumByteCount: UInt64, logicalName: String) throws -> Data {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw NativeModelGraphPackageError.missingFile(logicalName)
		}
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
			throw NativeModelGraphPackageError.symbolicLinkNotAllowed(logicalName)
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
		guard isSHA256(manifest.weightsSHA256) else {
			throw NativeModelGraphPackageError.invalidManifest("weightsSHA256 must be a lowercase 64-character SHA-256 digest")
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
			max(currentMaximum, weight.offset + weight.byteCount)
		}
	}
}

public enum NativeModelGraphPackageError: Error, Equatable, LocalizedError, Sendable {
	case notDirectory(String)
	case missingFile(String)
	case symbolicLinkNotAllowed(String)
	case invalidFileMetadata(String)
	case fileTooLarge(file: String, actualByteCount: UInt64, maximumByteCount: UInt64)
	case invalidManifest(String)
	case invalidGraphJSON(String)
	case invalidGraph([NativeModelGraphValidationIssue])
	case weightsChecksumMismatch(expected: String, actual: String)
	case truncatedWeights(requiredByteCount: UInt64, actualByteCount: UInt64)

	public var errorDescription: String? {
		switch self {
		case .notDirectory(let name):
			"Native model package '\(name)' is not a directory."
		case .missingFile(let name):
			"Native model package is missing '\(name)'."
		case .symbolicLinkNotAllowed(let name):
			"Native model package file '\(name)' must not be a symbolic link."
		case .invalidFileMetadata(let name):
			"Native model package file '\(name)' has invalid metadata."
		case .fileTooLarge(let file, let actualByteCount, let maximumByteCount):
			"Native model package file '\(file)' has \(actualByteCount) bytes; the limit is \(maximumByteCount)."
		case .invalidManifest(let reason):
			"Native model package manifest is invalid: \(reason)."
		case .invalidGraphJSON(let reason):
			"Native model graph JSON is invalid: \(reason)."
		case .invalidGraph(let issues):
			"Native model graph is invalid: \(issues.map(\.localizedDescription).joined(separator: "; "))."
		case .weightsChecksumMismatch(let expected, let actual):
			"Native model weights checksum mismatch: expected \(expected), got \(actual)."
		case .truncatedWeights(let requiredByteCount, let actualByteCount):
			"Native model graph requires \(requiredByteCount) weight bytes, but weights.bin has \(actualByteCount)."
		}
	}
}
