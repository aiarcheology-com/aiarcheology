//
//  FileManager+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import Foundation
import OSLog

extension FileManager {
	/// Returns the configuration directory for a specific model ID
	static func deepConfigurationDirectory(id: UUID) -> URL? {
		return FileManager.default.documentDirectory?
				.appendingPathComponent("Configurations")
				.appendingPathComponent(id.uuidString)
	}
	
	/// Returns the user's Documents directory URL
	var documentDirectory: URL? {
		urls(for: .documentDirectory, in: .userDomainMask).first
	}
	
	// MARK: - Model File Storage
	
	/// Prepares target directory and returns target URL, removing any existing file.
	private static func prepareTargetURL(from sourceURL: URL, configurationId: UUID) throws -> URL {
		guard let targetDirectory = deepConfigurationDirectory(id: configurationId) else {
			throw ModelFileStorageError.cannotCreateTargetDirectory
		}
		
		let fm = FileManager.default
		try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
		
		let targetURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
		
		// The existing target is deleted next. When the source *is* that file, reached through a
		// path that no lexical check recognises (a symlink, a `/private` alias, `..`), deleting
		// it would destroy the model before the copy or move could read it (AIA-0963). Only
		// filesystem identity answers that question.
		if isSameFile(sourceURL, targetURL) {
			throw ModelFileStorageError.fileOperationFailed
		}
		
		if fm.fileExists(atPath: targetURL.path) {
			try fm.removeItem(at: targetURL)
		}
		
		return targetURL
	}
	
	/// Whether both URLs name the same existing file, compared by filesystem identity rather than
	/// by path. `false` when either identity cannot be read, for example because the target does
	/// not exist yet; storage then proceeds exactly as it did before this guard.
	private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
		let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
		guard
			let lhsID = try? lhs.resourceValues(forKeys: key).fileResourceIdentifier,
			let rhsID = try? rhs.resourceValues(forKeys: key).fileResourceIdentifier
		else {
			return false
		}
		return lhsID.isEqual(rhsID)
	}
	
	/// Moves a downloaded model file to the app's Documents directory.
	/// Use this for temporary download files that should be removed from source.
	/// - Parameters:
	///   - sourceURL: The temporary location of the downloaded file
	///   - configurationId: The UUID of the configuration to store the file under
	/// - Returns: The URL of the file in its new location
	static func moveModelToDocuments(from sourceURL: URL, configurationId: UUID) throws -> URL {
		let targetURL = try prepareTargetURL(from: sourceURL, configurationId: configurationId)
		try FileManager.default.moveItem(at: sourceURL, to: targetURL)
		LoggingPolicy.debug("Model moved to: \(targetURL.path)", logger: .storage)
		return targetURL
	}
	
	/// Copies an external model file to the app's Documents directory.
	/// Use this for file picker imports where the source should be preserved.
	/// Handles security-scoped resource access for sandboxed file picker URLs.
	/// - Parameters:
	///   - sourceURL: The external file URL (e.g., from file picker)
	///   - configurationId: The UUID of the configuration to store the file under
	/// - Returns: The URL of the file in its new location
	static func copyModelToDocuments(from sourceURL: URL, configurationId: UUID) throws -> URL {
		let accessGranted = sourceURL.startAccessingSecurityScopedResource()
		defer {
			if accessGranted {
				sourceURL.stopAccessingSecurityScopedResource()
			}
		}
		
		let targetURL = try prepareTargetURL(from: sourceURL, configurationId: configurationId)
		try FileManager.default.copyItem(at: sourceURL, to: targetURL)
		LoggingPolicy.debug("Model copied to: \(targetURL.path)", logger: .storage)
		return targetURL
	}
	
	/// Stores a model file in the app's Documents directory.
	/// Automatically determines whether to copy or move based on the source location.
	/// - Parameters:
	///   - sourceURL: The source file URL
	///   - configurationId: The UUID of the configuration to store the file under
	///   - preferMove: If true and file is in a temp location, moves instead of copying
	/// - Returns: The URL of the file in Documents, or the original URL if already there
	/// - Throws: ``ModelFileStorageError/fileOperationFailed`` for the Documents directory itself or
	///   a source path with a `.`/`..` component (see below).
	///
	/// Every location test here is ``URL/isStrictlyContained(in:)``, the same lexical,
	/// whole-component check that ``URL/relativePath(from:)`` applies to the returned URL, so the
	/// two cannot disagree (AIA-0963). They are not standardized, for the reason documented on the
	/// helper. A lexical miss on the temporary-location test produces a copy, which is always safe.
	static func storeModelInDocuments(from sourceURL: URL, configurationId: UUID, preferMove: Bool = false) throws -> URL {
		let fileManager = FileManager.default
		guard let documentsURL = fileManager.documentDirectory else {
			throw ModelFileStorageError.cannotAccessDocuments
		}
		
		// Rejected rather than copied. A `..` path can name the copy target itself, such as
		// `Configurations/<id>/../<id>/model`, and `prepareTargetURL` deletes the target before
		// copying, which would destroy the source. Documents itself is not a model file.
		let sourceComponents = sourceURL.pathComponents
		if sourceComponents.contains(where: { $0 == "." || $0 == ".." })
			|| sourceComponents == documentsURL.pathComponents {
			throw ModelFileStorageError.fileOperationFailed
		}
		
		if sourceURL.isStrictlyContained(in: documentsURL) {
			return sourceURL
		}
		
		// Decides move versus copy, so a false positive would move a user's file out of its original
		// location: only the real temporary and Caches directories count, never a `tmp` or `Caches`
		// component elsewhere.
		let temporaryRoots = [fileManager.temporaryDirectory]
			+ fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
		let isTemporaryFile = temporaryRoots.contains { sourceURL.isStrictlyContained(in: $0) }
		
		if preferMove && isTemporaryFile {
			return try moveModelToDocuments(from: sourceURL, configurationId: configurationId)
		} else {
			return try copyModelToDocuments(from: sourceURL, configurationId: configurationId)
		}
	}
}

// MARK: - Errors

enum ModelFileStorageError: LocalizedError {
	case cannotCreateTargetDirectory
	case cannotAccessDocuments
	case fileOperationFailed
	
	var errorDescription: String? {
		switch self {
		case .cannotCreateTargetDirectory:
			return "Could not create the storage directory for the model."
		case .cannotAccessDocuments:
			return "Could not access the app's Documents directory."
		case .fileOperationFailed:
			return "Failed to store the model file."
		}
	}
}
