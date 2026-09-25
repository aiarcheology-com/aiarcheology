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
		FileManager.default.documentDirectory.map { configurationDirectory(id: id, in: $0) }
	}
	
	/// The configuration directory for `id` under `documentsURL`. Every model storage function
	/// takes Documents as a parameter defaulting to the real one, so a test can store into a fixture
	/// tree instead of the app container (AIA-0968).
	static func configurationDirectory(id: UUID, in documentsURL: URL) -> URL {
		documentsURL
			.appendingPathComponent("Configurations")
			.appendingPathComponent(id.uuidString)
	}
	
	/// Returns the user's Documents directory URL
	var documentDirectory: URL? {
		urls(for: .documentDirectory, in: .userDomainMask).first
	}
	
	// MARK: - Model File Storage
	
	/// Validates a store, creates the target directory, and returns the target URL. An existing
	/// target is left in place; ``installItem(at:stage:)`` replaces it only once its successor is
	/// complete (AIA-0967).
	private static func prepareTargetURL(from sourceURL: URL, configurationId: UUID, documentsURL: URL?) throws -> URL {
		guard let documentsURL else {
			throw ModelFileStorageError.cannotCreateTargetDirectory
		}
		
		let targetDirectory = configurationDirectory(id: configurationId, in: documentsURL)
		let targetURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
		
		// A source that contains its own target, such as the app container, would be copied into
		// itself, and the copy could keep going until the disk is full (AIA-0968). Rejected before
		// anything is created. `Downloader` calls `moveModelToDocuments` directly, so the check lives
		// here rather than in `storeModelInDocuments`.
		if isTarget(targetURL, insideSource: sourceURL) {
			throw ModelFileStorageError.fileOperationFailed
		}
		
		// When the source *is* the target file, reached through a path that no lexical check
		// recognises (a symlink, a `/private` alias, `..`), replacing the target would discard the
		// model it is being replaced with (AIA-0963). Only filesystem identity answers that question.
		if isSameFile(sourceURL, targetURL) {
			throw ModelFileStorageError.fileOperationFailed
		}
		
		try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
		return targetURL
	}
	
	/// Whether `targetURL` lies strictly inside `sourceURL`. Decided lexically on whole path
	/// components, and also by filesystem identity for every proper prefix of the target's path,
	/// because an alias of the container (a symlink, a `/private` spelling, a `..` component) passes
	/// the lexical check. Walking prefixes rather than repeatedly deleting the last component means a
	/// `..` in the path cannot end the walk early. The source's identity is read once, then one
	/// identity read per prefix, a dozen at most. For a source that exists, the identity walk alone
	/// would decide; the lexical test is the cheap, spelled-out form of the same rule and needs no
	/// filesystem access.
	private static func isTarget(_ targetURL: URL, insideSource sourceURL: URL) -> Bool {
		if targetURL.isStrictlyContained(in: sourceURL) {
			return true
		}
		guard let sourceID = fileIdentity(of: sourceURL) else {
			return false
		}
		let components = targetURL.pathComponents
		return (1..<components.count).contains { count in
			let ancestor = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count))))
			return fileIdentity(of: ancestor)?.isEqual(sourceID) == true
		}
	}
	
	/// Whether both URLs name the same existing file, compared by filesystem identity rather than
	/// by path. `false` when either identity cannot be read, for example because the target does not
	/// exist yet; storage then proceeds exactly as it did before this guard.
	private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
		guard let lhsID = fileIdentity(of: lhs), let rhsID = fileIdentity(of: rhs) else {
			return false
		}
		return lhsID.isEqual(rhsID)
	}
	
	/// The filesystem identity of the item `url` names, or `nil` when it cannot be read. Symlinks are
	/// resolved first, because resource values describe a link itself rather than the file it points to.
	private static func fileIdentity(of url: URL) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
		try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
	}
	
	/// Puts a new item at `targetURL` without losing the one already there (AIA-0967).
	///
	/// `stage` writes the new item to a hidden sibling of the target, in the same directory and so on
	/// the same volume. Only when that succeeds does `replaceItemAt` swap it in; the old item is
	/// removed after the swap, never before. If staging fails, the partial staged item is removed. If
	/// the swap fails, `unstage` disposes of the staged item (a move puts it back at its source), and
	/// an original that `replaceItemAt` had already moved aside is put back, so the existing target
	/// stays in place. `.usingNewMetadataOnly` keeps the result identical to a fresh store, as the
	/// previous delete-then-place order produced. The cost of keeping the old item until the new one
	/// is complete: a copy briefly needs space for both, where the old order needed space for one.
	/// A move is a rename and needs none.
	///
	/// A crash between staging and swapping leaves a `.<name>.staging-<UUID>` sibling, possibly as
	/// large as the model. Nothing else removes it: a configuration with a download item keeps its
	/// directory on deletion. So every install first sweeps stale siblings for its own name, as the
	/// converter does for its `.partial-` files. That assumes one install at a time per target:
	/// `Downloader.downloadTapped` ignores a start while a catalog item is downloading, imports run
	/// one at a time (`ModelImportView.startImport`), a retried conversion's source is already inside
	/// Documents and is not installed again, and every other store has a fresh configuration ID or a
	/// unique download filename.
	///
	/// A loaded model is not affected by the swap. Only a catalog re-download reuses both a
	/// configuration ID and a filename, and catalog artifacts are sources (`.mlmodel`, `.mlpackage`,
	/// `.onnx`), never compiled bundles. Core ML runs the `.mlmodelc` that `MLModel.compileModel(at:)`
	/// writes to a temporary location, so a loaded model never reads the stored file; the next load
	/// compiles the new one. A converted `.onnx` keeps its existing converted model until the import
	/// flow converts again. A compile that is reading the old file at the moment of the swap can fail
	/// with an error; it cannot damage either stored model.
	///
	/// - Returns: The URL that now holds the new item, as `replaceItemAt` reports it.
	private static func installItem(
		at targetURL: URL,
		stage: (URL) throws -> Void,
		unstage: (URL) -> Void
	) throws -> URL {
		let fileManager = FileManager.default
		let directory = targetURL.deletingLastPathComponent()
		let stagingPrefix = ".\(targetURL.lastPathComponent).staging-"
		if let siblings = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
			for sibling in siblings where sibling.lastPathComponent.hasPrefix(stagingPrefix) {
				try? fileManager.removeItem(at: sibling)
			}
		}
		
		let stagingURL = directory.appendingPathComponent(stagingPrefix + UUID().uuidString)
		do {
			try stage(stagingURL)
		} catch {
			try? fileManager.removeItem(at: stagingURL)
			throw error
		}
		
		do {
			guard fileManager.fileExists(atPath: targetURL.path) else {
				try fileManager.moveItem(at: stagingURL, to: targetURL)
				return targetURL
			}
			do {
				let installedURL = try fileManager.replaceItemAt(
					targetURL,
					withItemAt: stagingURL,
					options: .usingNewMetadataOnly
				)
				return installedURL ?? targetURL
			} catch {
				restoreOriginal(at: targetURL, after: error)
				throw error
			}
		} catch {
			unstage(stagingURL)
			throw error
		}
	}
	
	/// The user-info key under which a failed `replaceItemAt` reports where it left the original.
	/// Foundation documents the string in `NSFileManager.h` but exports no Swift constant for it.
	private static let originalItemLocationKey = "NSFileOriginalItemLocationKey"
	
	/// `replaceItemAt` does not promise to leave the original where it was when it fails; when it has
	/// moved the original aside, the error names where. Put it back, best effort.
	private static func restoreOriginal(at targetURL: URL, after error: Error) {
		let fileManager = FileManager.default
		guard
			fileManager.fileExists(atPath: targetURL.path).not,
			let originalURL = (error as NSError).userInfo[originalItemLocationKey] as? URL
		else {
			return
		}
		try? fileManager.moveItem(at: originalURL, to: targetURL)
	}
	
	/// Moves a downloaded model file to the app's Documents directory.
	/// Use this for temporary download files that should be removed from source.
	/// An existing file of the same name is replaced only once the move has succeeded (AIA-0967);
	/// if the replacement fails, the download is moved back to `sourceURL`.
	/// Throws ``ModelFileStorageError/fileOperationFailed`` when the source already is the target
	/// file or contains the target (AIA-0968).
	/// - Parameters:
	///   - sourceURL: The temporary location of the downloaded file
	///   - configurationId: The UUID of the configuration to store the file under
	///   - documentsURL: The Documents directory to store under; tests pass a fixture
	/// - Returns: The URL of the file in its new location
	static func moveModelToDocuments(
		from sourceURL: URL,
		configurationId: UUID,
		documentsURL: URL? = FileManager.default.documentDirectory
	) throws -> URL {
		let fileManager = FileManager.default
		let targetURL = try prepareTargetURL(from: sourceURL, configurationId: configurationId, documentsURL: documentsURL)
		let installedURL = try installItem(
			at: targetURL,
			stage: { stagingURL in try fileManager.moveItem(at: sourceURL, to: stagingURL) },
			unstage: { stagingURL in
				// Leaves no staged item either way; a download that cannot go back is fetched again.
				if (try? fileManager.moveItem(at: stagingURL, to: sourceURL)) == nil {
					try? fileManager.removeItem(at: stagingURL)
				}
			}
		)
		LoggingPolicy.debug("Model moved to: \(installedURL.path)", logger: .storage)
		return installedURL
	}
	
	/// Copies an external model file to the app's Documents directory.
	/// Use this for file picker imports where the source should be preserved.
	/// Handles security-scoped resource access for sandboxed file picker URLs.
	/// An existing file of the same name is replaced only once the copy has succeeded (AIA-0967).
	/// Throws ``ModelFileStorageError/fileOperationFailed`` when the source already is the target
	/// file or contains the target (AIA-0968).
	/// - Parameters:
	///   - sourceURL: The external file URL (e.g., from file picker)
	///   - configurationId: The UUID of the configuration to store the file under
	///   - documentsURL: The Documents directory to store under; tests pass a fixture
	/// - Returns: The URL of the file in its new location
	static func copyModelToDocuments(
		from sourceURL: URL,
		configurationId: UUID,
		documentsURL: URL? = FileManager.default.documentDirectory
	) throws -> URL {
		let accessGranted = sourceURL.startAccessingSecurityScopedResource()
		defer {
			if accessGranted {
				sourceURL.stopAccessingSecurityScopedResource()
			}
		}
		
		let fileManager = FileManager.default
		let targetURL = try prepareTargetURL(from: sourceURL, configurationId: configurationId, documentsURL: documentsURL)
		let installedURL = try installItem(
			at: targetURL,
			stage: { stagingURL in try fileManager.copyItem(at: sourceURL, to: stagingURL) },
			unstage: { stagingURL in try? fileManager.removeItem(at: stagingURL) }
		)
		LoggingPolicy.debug("Model copied to: \(installedURL.path)", logger: .storage)
		return installedURL
	}
	
	/// Stores a model file in the app's Documents directory.
	/// Automatically determines whether to copy or move based on the source location.
	/// - Parameters:
	///   - sourceURL: The source file URL
	///   - configurationId: The UUID of the configuration to store the file under
	///   - preferMove: If true and file is in a temp location, moves instead of copying
	///   - documentsURL: The Documents directory to store under; tests pass a fixture
	/// - Returns: The URL of the file in Documents, or the original URL if already there
	/// - Throws: ``ModelFileStorageError/fileOperationFailed`` for the Documents directory itself, a
	///   source path with a `.`/`..` component (see below), a source that is the target file under
	///   another spelling, or a source that contains the target, such as the app container.
	///
	/// Every location test here is ``URL/isStrictlyContained(in:)``, the same lexical,
	/// whole-component check that ``URL/relativePath(from:)`` applies to the returned URL, so the
	/// two apply one rule (AIA-0963). They are not standardized, for the reason documented on the
	/// helper. A lexical miss on the temporary-location test produces a copy, which is always safe.
	static func storeModelInDocuments(
		from sourceURL: URL,
		configurationId: UUID,
		preferMove: Bool = false,
		documentsURL: URL? = FileManager.default.documentDirectory
	) throws -> URL {
		let fileManager = FileManager.default
		guard let documentsURL else {
			throw ModelFileStorageError.cannotAccessDocuments
		}
		
		// Rejected rather than copied. A `..` path can name the copy target itself, such as
		// `Configurations/<id>/../<id>/model`, which the store would replace with a copy of itself.
		// Documents itself is not a model file.
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
		if preferMove && temporaryRoots.contains(where: { sourceURL.isStrictlyContained(in: $0) }) {
			return try moveModelToDocuments(from: sourceURL, configurationId: configurationId, documentsURL: documentsURL)
		} else {
			return try copyModelToDocuments(from: sourceURL, configurationId: configurationId, documentsURL: documentsURL)
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
