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

	func relativePath(from directory: FileManager.SearchPathDirectory) throws -> URL {
		let fileManager = FileManager.default

		guard let directoryURL = try? fileManager.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false) else {
			throw CocoaError(.fileNoSuchFile)
		}

		// Containment is decided on whole path components (AIA-0606): a bare string prefix also
		// matched a sibling such as `…/DocumentsBackup` and silently produced a wrong relative
		// path. The URL must lie strictly inside the directory; the directory itself is not a
		// file within it, and a `.`/`..` component below it could climb back out. Lexical only,
		// as before — this does not resolve symlinks or a `/private` prefix.
		let directoryComponents = directoryURL.pathComponents
		let components = self.pathComponents
		let relativeComponents = components.dropFirst(directoryComponents.count)

		guard
			components.count > directoryComponents.count,
			components.starts(with: directoryComponents),
			relativeComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
			throw CocoaError(.fileNoSuchFile)
		}

		let relativePath = relativeComponents.joined(separator: "/")

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
