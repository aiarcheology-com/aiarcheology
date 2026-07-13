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

/// Downloads package siblings into a temporary directory. `Downloader` owns the returned package
/// root and moves it into the model configuration directory before the normal import flow begins.
actor CatalogPackageDownloader {
	static let maximumTotalBytes: Int64 = 1_500_000_000
	static let maximumFileCount = 500
	static let maximumUnknownSizeFileCount = 100
	private static let maximumConcurrentDownloads = 3

	private let session: URLSession
	private let fileManager: FileManager

	init(session: URLSession = .shared, fileManager: FileManager = .default) {
		self.session = session
		self.fileManager = fileManager
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
			var downloadedBytes: Int64 = 0
			var completedFileCount = 0
			let knownTotal = unknownSizeCount == 0 ? expectedBytes : nil
			reportProgress(
				CatalogPackageDownloadProgress(
					completedFileCount: completedFileCount,
					totalFileCount: files.count,
					downloadedBytes: downloadedBytes,
					expectedBytes: knownTotal
				)
			)

			if files.count == 1, let file = files.first, file.xetFile != nil {
				let downloaded = try await Self.fetch(file: file, session: session) { bytesWritten in
					reportProgress(
						CatalogPackageDownloadProgress(
							completedFileCount: 0,
							totalFileCount: 1,
							downloadedBytes: bytesWritten,
							expectedBytes: knownTotal
						)
					)
				}
				downloadedBytes = downloaded.byteCount
				guard downloadedBytes <= Self.maximumTotalBytes else { throw CatalogError.tooLarge }
				try stage(downloaded: downloaded, in: stagingRoot)
				completedFileCount = 1
				reportProgress(
					CatalogPackageDownloadProgress(
						completedFileCount: completedFileCount,
						totalFileCount: files.count,
						downloadedBytes: downloadedBytes,
						expectedBytes: knownTotal
					)
				)
			} else {
				try await withThrowingTaskGroup(of: DownloadedFile.self) { group in
					var nextIndex = 0
					let initialCount = min(Self.maximumConcurrentDownloads, files.count)
					for _ in 0..<initialCount {
						let file = files[nextIndex]
						nextIndex += 1
						group.addTask { [session] in
							try await Self.fetch(file: file, session: session)
						}
					}

					while let downloaded = try await group.next() {
						downloadedBytes += downloaded.byteCount
						guard downloadedBytes <= Self.maximumTotalBytes else { throw CatalogError.tooLarge }
						try stage(downloaded: downloaded, in: stagingRoot)
						completedFileCount += 1
						reportProgress(
							CatalogPackageDownloadProgress(
								completedFileCount: completedFileCount,
								totalFileCount: files.count,
								downloadedBytes: downloadedBytes,
								expectedBytes: knownTotal
							)
						)

						if nextIndex < files.count {
							let file = files[nextIndex]
							nextIndex += 1
							group.addTask { [session] in
								try await Self.fetch(file: file, session: session)
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
		onBytesWritten: @escaping @Sendable (Int64) -> Void = { _ in }
	) async throws -> DownloadedFile {
		do {
			let temporaryURL: URL
			if file.xetFile != nil {
				temporaryURL = try await HuggingFaceXetDownloader.download(
					file: file,
					session: session,
					onBytesWritten: onBytesWritten
				)
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
