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
		
		if fm.fileExists(atPath: targetURL.path) {
			try fm.removeItem(at: targetURL)
		}
		
		return targetURL
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
		Logger.storage.logDebug("Model moved to: \(targetURL.path)")
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
		Logger.storage.logDebug("Model copied to: \(targetURL.path)")
		return targetURL
	}
	
	/// Stores a model file in the app's Documents directory.
	/// Automatically determines whether to copy or move based on the source location.
	/// - Parameters:
	///   - sourceURL: The source file URL
	///   - configurationId: The UUID of the configuration to store the file under
	///   - preferMove: If true and file is in a temp location, moves instead of copying
	/// - Returns: The URL of the file in Documents, or the original URL if already there
	static func storeModelInDocuments(from sourceURL: URL, configurationId: UUID, preferMove: Bool = false) throws -> URL {
		guard let documentsPath = FileManager.default.documentDirectory?.path else {
			throw ModelFileStorageError.cannotAccessDocuments
		}
		
		if sourceURL.path.hasPrefix(documentsPath) {
			return sourceURL
		}
		
		let isTemporaryFile = sourceURL.path.contains("/tmp/") || sourceURL.path.contains("/Caches/")
		
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
