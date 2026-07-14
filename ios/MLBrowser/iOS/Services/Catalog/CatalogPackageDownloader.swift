//
//  CatalogPackageDownloader.swift
//  AI Archeology
//
//  AIA-0413: bounded multi-file Core ML package download and staging.
//

import Foundation

struct CatalogPackageDownloadProgress: Sendable, Equatable {
	let completedFileCount: Int
	let totalFileCount: Int
	let downloadedBytes: Int64
	let expectedBytes: Int64?

	var fractionCompleted: Double {
		if let expectedBytes, expectedBytes > 0 {
			return min(Double(downloadedBytes) / Double(expectedBytes), 1)
		}
		guard totalFileCount > 0 else { return 0 }
		return Double(completedFileCount) / Double(totalFileCount)
	}
}

enum CatalogPackageDownloadEvent: Sendable {
	case progress(CatalogPackageDownloadProgress)
	case finished(URL)
}

typealias CatalogXetDownload = @Sendable (
	_ file: CatalogFile,
	_ session: URLSession,
	_ onBytesWritten: @escaping @Sendable (Int64) -> Void
) async throws -> URL

/// Downloads package siblings into a temporary directory. `Downloader` owns the returned package
/// root and moves it into the model configuration directory before the normal import flow begins.
actor CatalogPackageDownloader {
	static let maximumTotalBytes: Int64 = 1_500_000_000
	static let maximumFileCount = 500
	static let maximumUnknownSizeFileCount = 100
	private static let maximumConcurrentDownloads = 3

	private let session: URLSession
	private let fileManager: FileManager
	private let xetDownload: CatalogXetDownload

	init(
		session: URLSession = .shared,
		fileManager: FileManager = .default,
		xetDownload: @escaping CatalogXetDownload = { file, session, onBytesWritten in
			try await HuggingFaceXetDownloader.download(
				file: file,
				session: session,
				onBytesWritten: onBytesWritten
			)
		}
	) {
		self.session = session
		self.fileManager = fileManager
		self.xetDownload = xetDownload
	}

	func events(for files: [CatalogFile]) -> AsyncThrowingStream<CatalogPackageDownloadEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let packageURL = try await self.download(files: files) { progress in
						continuation.yield(.progress(progress))
					}
					continuation.yield(.finished(packageURL))
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

private extension CatalogPackageDownloader {
	struct DownloadedFile: Sendable {
		let file: CatalogFile
		let temporaryURL: URL
		let byteCount: Int64
	}

	/// Serializes progress emitted by concurrent package-file tasks into a single aggregate value.
	final class ProgressReporter: @unchecked Sendable {
		private let lock = NSLock()
		private let totalFileCount: Int
		private let expectedBytes: Int64?
		private let report: @Sendable (CatalogPackageDownloadProgress) -> Void
		private var bytesByPath: [String: Int64] = [:]
		private var completedPaths = Set<String>()

		init(
			files: [CatalogFile],
			expectedBytes: Int64?,
			report: @escaping @Sendable (CatalogPackageDownloadProgress) -> Void
		) {
			totalFileCount = files.count
			self.expectedBytes = expectedBytes
			self.report = report
		}

		func reportInitialProgress() {
			report(
				CatalogPackageDownloadProgress(
					completedFileCount: 0,
					totalFileCount: totalFileCount,
					downloadedBytes: 0,
					expectedBytes: expectedBytes
				)
			)
		}

		func update(file: CatalogFile, downloadedBytes: Int64) {
			report(snapshot(updating: file, downloadedBytes: downloadedBytes, isComplete: false))
		}

		func complete(file: CatalogFile, downloadedBytes: Int64) {
			report(snapshot(updating: file, downloadedBytes: downloadedBytes, isComplete: true))
		}

		private func snapshot(
			updating file: CatalogFile,
			downloadedBytes: Int64,
			isComplete: Bool
		) -> CatalogPackageDownloadProgress {
			lock.lock()
			bytesByPath[file.relativePath] = max(bytesByPath[file.relativePath] ?? 0, downloadedBytes)
			if isComplete {
				completedPaths.insert(file.relativePath)
			}
			let progress = CatalogPackageDownloadProgress(
				completedFileCount: completedPaths.count,
				totalFileCount: totalFileCount,
				downloadedBytes: bytesByPath.values.reduce(0, +),
				expectedBytes: expectedBytes
			)
			lock.unlock()
			return progress
		}
	}

	func download(
		files: [CatalogFile],
		reportProgress: @escaping @Sendable (CatalogPackageDownloadProgress) -> Void
	) async throws -> URL {
		let artifact = try validate(files: files)
		let expectedBytes = files.compactMap(\.sizeBytes).reduce(Int64(0), +)
		let unknownSizeCount = files.filter { $0.sizeBytes == nil }.count
		guard expectedBytes <= Self.maximumTotalBytes else { throw CatalogError.tooLarge }
		guard unknownSizeCount <= Self.maximumUnknownSizeFileCount else { throw CatalogError.tooLarge }

		let stagingRoot = fileManager.temporaryDirectory
			.appendingPathComponent("CatalogPackages", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

		do {
			let knownTotal = unknownSizeCount == 0 ? expectedBytes : nil
			let progressReporter = ProgressReporter(files: files, expectedBytes: knownTotal, report: reportProgress)
			progressReporter.reportInitialProgress()
			var downloadedBytes: Int64 = 0

			try await withThrowingTaskGroup(of: DownloadedFile.self) { group in
				var nextIndex = 0
				let initialCount = min(Self.maximumConcurrentDownloads, files.count)
				for _ in 0..<initialCount {
					let file = files[nextIndex]
					nextIndex += 1
					group.addTask { [session, progressReporter, xetDownload] in
						try await Self.fetch(file: file, session: session, xetDownload: xetDownload) { bytesWritten in
							progressReporter.update(file: file, downloadedBytes: bytesWritten)
						}
					}
				}

				while let downloaded = try await group.next() {
					downloadedBytes += downloaded.byteCount
					guard downloadedBytes <= Self.maximumTotalBytes else { throw CatalogError.tooLarge }
					try stage(downloaded: downloaded, in: stagingRoot)
					progressReporter.complete(file: downloaded.file, downloadedBytes: downloaded.byteCount)

					if nextIndex < files.count {
						let file = files[nextIndex]
						nextIndex += 1
						group.addTask { [session, progressReporter, xetDownload] in
							try await Self.fetch(file: file, session: session, xetDownload: xetDownload) { bytesWritten in
								progressReporter.update(file: file, downloadedBytes: bytesWritten)
							}
						}
					}
				}
			}

			let artifactURL: URL
			switch artifact {
			case .package(let root):
				artifactURL = stagingRoot.appendingPathComponent(root, isDirectory: true)
			case .singleFile(let relativePath):
				artifactURL = try destinationURL(for: relativePath, in: stagingRoot)
			}
			guard fileManager.fileExists(atPath: artifactURL.path) else {
				throw CatalogError.noInstallableArtifact
			}
			return artifactURL
		} catch {
			try? fileManager.removeItem(at: stagingRoot)
			throw error
		}
	}

	enum Artifact {
		case package(String)
		case singleFile(String)
	}

	func validate(files: [CatalogFile]) throws -> Artifact {
		guard files.isEmpty == false, files.count <= Self.maximumFileCount else {
			throw files.isEmpty ? CatalogError.noInstallableArtifact : CatalogError.tooManyFiles
		}
		if files.count == 1, let file = files.first, file.relativePath.lowercased().hasSuffix(".mlmodel") {
			return .singleFile(file.relativePath)
		}

		let roots = Set(files.compactMap { packageRoot(in: $0.relativePath) })
		guard roots.count == 1, let root = roots.first else {
			throw CatalogError.invalidFilePath
		}
		return .package(root)
	}

	func stage(downloaded: DownloadedFile, in stagingRoot: URL) throws {
		let destination = try destinationURL(for: downloaded.file.relativePath, in: stagingRoot)
		try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.removeItem(at: destination)
		}
		try fileManager.moveItem(at: downloaded.temporaryURL, to: destination)
	}

	nonisolated static func fetch(
		file: CatalogFile,
		session: URLSession,
		xetDownload: @escaping CatalogXetDownload,
		onBytesWritten: @escaping @Sendable (Int64) -> Void = { _ in }
	) async throws -> DownloadedFile {
		do {
			let temporaryURL: URL
			if file.xetFile != nil {
				temporaryURL = try await xetDownload(file, session, onBytesWritten)
			} else {
				let (downloadURL, response) = try await session.download(from: file.resolveURL)
				guard let response = response as? HTTPURLResponse,
					  (200...299).contains(response.statusCode) else {
					throw CatalogError.network
				}
				temporaryURL = downloadURL
			}
			let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
			guard let size = values.fileSize else { throw CatalogError.invalidResponse }
			return DownloadedFile(file: file, temporaryURL: temporaryURL, byteCount: Int64(size))
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as CatalogError {
			throw error
		} catch {
			throw CatalogError.network
		}
	}

	func destinationURL(for relativePath: String, in stagingRoot: URL) throws -> URL {
		let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
		guard components.isEmpty == false,
			  components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
			throw CatalogError.invalidFilePath
		}

		let destination = components.reduce(stagingRoot) { partialResult, component in
			partialResult.appendingPathComponent(String(component))
		}.standardizedFileURL
		guard destination.path.hasPrefix(stagingRoot.standardizedFileURL.path + "/") else {
			throw CatalogError.invalidFilePath
		}
		return destination
	}

	func packageRoot(in path: String) -> String? {
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		guard let packageIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".mlpackage") }) else {
			return nil
		}
		return components[...packageIndex].joined(separator: "/")
	}
}
