//
//  HuggingFaceXetDownloader.swift
//  AI Archeology
//
//  AIA-0413: official Hugging Face Xet transport bridge.
//

import Foundation
import HuggingFace

/// Downloads Xet-backed Hub files through Hugging Face's supported Swift client. The client writes
/// decoded Xet chunks directly to the destination, so polling the staged file reports actual bytes
/// without implementing the Xet protocol in the app.
enum HuggingFaceXetDownloader {
	private static let progressPollIntervalNanoseconds: UInt64 = 100_000_000

	static func download(
		file: CatalogFile,
		session: URLSession,
		onBytesWritten: @escaping @Sendable (Int64) -> Void = { _ in }
	) async throws -> URL {
		guard let xetFile = file.xetFile,
			  let repository = repository(for: file, xetFile: xetFile) else {
			throw CatalogError.invalidResponse
		}

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		let client = HubClient(
			session: session,
			host: hubURL(for: file, xetFile: xetFile),
			cache: nil
		)

		do {
			return try await downloadAndReportProgress(
				file: file,
				repository: repository,
				client: client,
				destination: destination,
				onBytesWritten: onBytesWritten
			)
		} catch is CancellationError {
			try? FileManager.default.removeItem(at: destination)
			throw CancellationError()
		} catch {
			try? FileManager.default.removeItem(at: destination)
			throw CatalogError.network
		}
	}
}

private extension HuggingFaceXetDownloader {
	static func downloadAndReportProgress(
		file: CatalogFile,
		repository: Repo.ID,
		client: HubClient,
		destination: URL,
		onBytesWritten: @escaping @Sendable (Int64) -> Void
	) async throws -> URL {
		try await withThrowingTaskGroup(of: URL.self) { group in
			group.addTask {
				try await client.downloadFile(
					at: file.relativePath,
					from: repository,
					to: destination,
					kind: .model,
					revision: "main",
					endpoint: .resolve,
					cachePolicy: .reloadIgnoringLocalCacheData,
					progress: nil,
					transport: .xet,
					localFilesOnly: false
				)
			}
			group.addTask {
				var lastReportedByteCount: Int64 = 0
				while Task.isCancelled == false {
					try await Task.sleep(nanoseconds: progressPollIntervalNanoseconds)
					let byteCount = fileSize(at: destination)
					guard byteCount > lastReportedByteCount else { continue }
					lastReportedByteCount = byteCount
					onBytesWritten(byteCount)
				}
				throw CancellationError()
			}

			guard let downloadedURL = try await group.next() else {
				throw CatalogError.network
			}
			group.cancelAll()
			onBytesWritten(fileSize(at: downloadedURL))
			return downloadedURL
		}
	}

	static func repository(for file: CatalogFile, xetFile: HuggingFaceXetFile) -> Repo.ID? {
		if let repositoryID = xetFile.repositoryID,
			let repository = Repo.ID(rawValue: repositoryID) {
			return repository
		}

		let components = file.resolveURL.pathComponents.dropFirst()
		guard let resolveIndex = components.firstIndex(of: "resolve") else { return nil }
		return Repo.ID(rawValue: components[..<resolveIndex].joined(separator: "/"))
	}

	static func hubURL(for file: CatalogFile, xetFile: HuggingFaceXetFile) -> URL {
		if let hubURL = xetFile.hubURL { return hubURL }
		guard var components = URLComponents(url: file.resolveURL, resolvingAgainstBaseURL: false) else {
			return HubClient.defaultHost
		}
		components.path = ""
		components.query = nil
		components.fragment = nil
		return components.url ?? HubClient.defaultHost
	}

	static func fileSize(at url: URL) -> Int64 {
		let values = try? url.resourceValues(forKeys: [.fileSizeKey])
		return values?.fileSize.map(Int64.init) ?? 0
	}
}
