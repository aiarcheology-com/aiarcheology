//
//  URL+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.11.23.
//

import Foundation

extension URL {
	/// Apple's account page for managing a subscription (cancel / change plan).
	///
	/// The substitute for StoreKit's in-app manage sheet on hosts that cannot present it — see
	/// ``HostPlatform/supportsManageSubscriptionsSheet``. Lives here, and not privately in each
	/// view, because the paywall and Settings → Account → Subscription both offer "Manage
	/// Subscription" and must not drift to different destinations.
	///
	/// The hardcoded literal always parses, so the force-unwrap cannot fail.
	// swiftlint:disable:next force_unwrapping
	static let appleManageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!

	/// Whether this URL names a Core ML bundle that is *already compiled* (`.mlmodelc`).
	///
	/// Core ML refuses to compile a compiled bundle a second time (`MLModel.compileModel(at:)` fails
	/// with a missing `Manifest.json`), so every loader must route on this instead of on where the
	/// model came from: an imported model is never a demo yet may well be compiled (AIA-0844). The
	/// extension is a routing decision only; Core ML still validates the bundle's contents on load.
	var isCompiledCoreMLModel: Bool {
		pathExtension.lowercased() == "mlmodelc"
	}

	func completePath(to directory: FileManager.SearchPathDirectory, isDirectory: Bool) throws -> URL {
		let baseDirectoryURL = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false)
		return baseDirectoryURL.appendingPathComponent(self.path, isDirectory: isDirectory)
	}

	/// Whether this URL lies strictly inside `directory`, decided on whole path components.
	///
	/// A bare string prefix also matches a sibling such as `…/DocumentsBackup` (AIA-0606, AIA-0963).
	/// The URL must lie strictly inside the directory: the directory itself is not a file within it,
	/// and a `.`/`..` component below it could climb back out.
	///
	/// **Lexical by design.** This neither standardizes nor resolves symlinks or a `/private` prefix.
	/// `standardizedFileURL` strips `/private` only when the path exists, so it is not a pure
	/// function of its input (AIA-0603). Every caller that uses this check and the URL it returns
	/// must therefore agree with the others lexically: ``relativePath(from:)`` and
	/// `FileManager.storeModelInDocuments` both use this helper for that reason.
	///
	/// `ImportedContainerRouting.restoredURL(of:namedBy:)` and
	/// `CatalogPackageDownloader.destinationURL(for:in:)` deliberately keep their own checks. Both
	/// validate the appended components first, then compare *standardized* values as defence in
	/// depth. The first never returns its standardized values. The second standardizes its root once
	/// and derives the destination it returns from that root. Neither is the lexical contract here,
	/// so they are not routed through this helper.
	func isStrictlyContained(in directory: URL) -> Bool {
		let directoryComponents = directory.pathComponents
		let components = pathComponents
		return components.count > directoryComponents.count
			&& components.starts(with: directoryComponents)
			&& components.dropFirst(directoryComponents.count).allSatisfy { $0 != "." && $0 != ".." }
	}

	func relativePath(from directory: FileManager.SearchPathDirectory) throws -> URL {
		let fileManager = FileManager.default

		guard let directoryURL = try? fileManager.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false) else {
			throw CocoaError(.fileNoSuchFile)
		}

		// Containment is decided on whole path components (AIA-0606); see `isStrictlyContained(in:)`.
		guard isStrictlyContained(in: directoryURL) else {
			throw CocoaError(.fileNoSuchFile)
		}

		let relativePath = pathComponents.dropFirst(directoryURL.pathComponents.count).joined(separator: "/")

		// .urlPathAllowed keeps "/" and "." intact; .alphanumerics encoded them
		// ("model.mlmodelc" → "model%2Emlmodelc") and only round-tripped by accident.
		guard let urlEncoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
			throw CocoaError(.fileWriteUnknown)
		}

		guard let relativeURL = URL(string: urlEncoded) else {
			throw CocoaError(.fileNoSuchFile)
		}

		return relativeURL
	}
}
