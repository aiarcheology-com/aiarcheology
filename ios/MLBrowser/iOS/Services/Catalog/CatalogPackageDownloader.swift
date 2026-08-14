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

/// The package transport deliberately uses the public HTTPS resolve URL for every file, including
/// files whose Hub metadata advertises Xet storage. Hugging Face resolves those URLs to its CDN,
/// while URLSession gives us reliable byte progress and cancellation semantics.
typealias CatalogHTTPDownload = @Sendable (
	_ file: CatalogFile,
	_ session: URLSession,
	_ onBytesWritten: @escaping @Sendable (Int64) -> Void
) async throws -> URL

struct CatalogHTTPDownloadTimeouts: Sendable, Equatable {
	let firstByte: TimeInterval
	let inactivity: TimeInterval

	static let standard = Self(firstByte: 20, inactivity: 60)
}

/// A single HTTP file transfer with delegate-based byte progress and explicit liveness bounds.
///
/// Each instance owns its own session so a package's bounded concurrent workers do not share
/// delegate state. The supplied configuration preserves custom URL protocols in offline tests.
final class CatalogHTTPFileDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
	private final class Transfer: @unchecked Sendable {
		let task: URLSessionDownloadTask
		let destinationURL: URL
		let onBytesWritten: @Sendable (Int64) -> Void
		let continuation: CheckedContinuation<URL, Error>
		var deadline: DispatchTime
		var watchdog: DispatchSourceTimer?

		init(
			task: URLSessionDownloadTask,
			destinationURL: URL,
			onBytesWritten: @escaping @Sendable (Int64) -> Void,
			continuation: CheckedContinuation<URL, Error>,
			deadline: DispatchTime
		) {
			self.task = task
			self.destinationURL = destinationURL
			self.onBytesWritten = onBytesWritten
			self.continuation = continuation
			self.deadline = deadline
		}
	}

	private let timeouts: CatalogHTTPDownloadTimeouts
	private let lock = NSLock()
	private var transfer: Transfer?
	private var cancelledBeforeStart = false
	private var session: URLSession?

	init(timeouts: CatalogHTTPDownloadTimeouts) {
		self.timeouts = timeouts
		super.init()
	}

	static func download(
		file: CatalogFile,
		session sourceSession: URLSession,
		timeouts: CatalogHTTPDownloadTimeouts = .standard,
		onBytesWritten: @escaping @Sendable (Int64) -> Void
	) async throws -> URL {
		let downloader = Self(timeouts: timeouts)
		return try await downloader.download(
			file: file,
			configuration: sourceSession.configuration,
			onBytesWritten: onBytesWritten
		)
	}

	func download(
		file: CatalogFile,
		configuration: URLSessionConfiguration,
		onBytesWritten: @escaping @Sendable (Int64) -> Void
	) async throws -> URL {
		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		self.session = session
		let task = session.downloadTask(with: file.resolveURL)

		return try await withTaskCancellationHandler(operation: {
			do {
				try Task.checkCancellation()
			} catch {
				session.invalidateAndCancel()
				throw error
			}
			return try await withCheckedThrowingContinuation { continuation in
				let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
				let transfer = Transfer(
					task: task,
					destinationURL: destinationURL,
					onBytesWritten: onBytesWritten,
					continuation: continuation,
					deadline: .now() + timeouts.firstByte
				)

				lock.lock()
				if cancelledBeforeStart {
					lock.unlock()
					session.invalidateAndCancel()
					continuation.resume(throwing: CancellationError())
					return
				}
				self.transfer = transfer
				armWatchdogLocked(for: transfer)
				task.resume()
				lock.unlock()
			}
		}, onCancel: { [weak self] in
			self?.cancel()
		})
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite _: Int64
	) {
		let callback: (@Sendable (Int64) -> Void)?
		lock.lock()
		if let transfer, transfer.task.taskIdentifier == downloadTask.taskIdentifier {
			transfer.deadline = .now() + timeouts.inactivity
			callback = transfer.onBytesWritten
		} else {
			callback = nil
		}
		lock.unlock()
		callback?(totalBytesWritten)
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
		guard let statusCode, (200...299).contains(statusCode) else {
			// The status code is collapsed into `.network` on the next line and cannot be recovered
			// anywhere downstream, so it is recorded here or not at all (AIA-0602). `originalRequest`
			// rather than `currentRequest`: a CDN redirect leaves the latter pointing at an opaque
			// blob key. Last path component only — a full URL, and any path of two or more
			// components, is redacted out of the default support export.
			LoggingPolicy.debug(
				CatalogPackageDownloader.httpFailureLogLine(
					fileName: downloadTask.originalRequest?.url?.lastPathComponent,
					statusCode: statusCode ?? -1
				),
				logger: .networking
			)
			finish(taskIdentifier: downloadTask.taskIdentifier, result: .failure(CatalogError.network))
			return
		}

		guard let transfer = takeTransfer(for: downloadTask.taskIdentifier) else { return }
		do {
			try FileManager.default.moveItem(at: location, to: transfer.destinationURL)
			complete(transfer, result: .success(transfer.destinationURL))
		} catch let error as CatalogError {
			complete(transfer, result: .failure(error))
		} catch {
			complete(transfer, result: .failure(CatalogError.network))
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let error else { return }
		if (error as? URLError)?.code == .timedOut {
			finish(taskIdentifier: task.taskIdentifier, result: .failure(CatalogError.timedOut))
		} else if error is CancellationError || (error as? URLError)?.code == .cancelled {
			finish(taskIdentifier: task.taskIdentifier, result: .failure(CancellationError()))
		} else {
			finish(taskIdentifier: task.taskIdentifier, result: .failure(CatalogError.network))
		}
	}

	private func takeTransfer(for taskIdentifier: Int) -> Transfer? {
		lock.lock()
		defer { lock.unlock() }
		return takeTransferLocked(for: taskIdentifier)
	}

	private func takeTransferLocked(for taskIdentifier: Int) -> Transfer? {
		guard let transfer, transfer.task.taskIdentifier == taskIdentifier else { return nil }
		self.transfer = nil
		transfer.watchdog?.setEventHandler {}
		transfer.watchdog?.cancel()
		transfer.watchdog = nil
		return transfer
	}

	private func armWatchdogLocked(for transfer: Transfer) {
		guard transfer.watchdog == nil else { return }
		let taskIdentifier = transfer.task.taskIdentifier
		let watchdog = DispatchSource.makeTimerSource(queue: .global())
		watchdog.setEventHandler { [weak self] in
			self?.watchdogFired(taskIdentifier: taskIdentifier)
		}
		transfer.watchdog = watchdog
		watchdog.schedule(deadline: transfer.deadline)
		watchdog.resume()
	}

	private func watchdogFired(taskIdentifier: Int) {
		let deadline: DispatchTime
		lock.lock()
		guard let transfer, transfer.task.taskIdentifier == taskIdentifier else {
			lock.unlock()
			return
		}
		deadline = transfer.deadline
		if DispatchTime.now() < deadline {
			transfer.watchdog?.schedule(deadline: deadline)
			lock.unlock()
			return
		}
		lock.unlock()
		timeout(taskIdentifier: taskIdentifier, deadline: deadline)
	}

	private func timeout(taskIdentifier: Int, deadline: DispatchTime) {
		let transfer: Transfer?
		lock.lock()
		if let currentTransfer = self.transfer, currentTransfer.task.taskIdentifier == taskIdentifier {
			if currentTransfer.deadline == deadline {
				transfer = takeTransferLocked(for: taskIdentifier)
			} else {
				currentTransfer.watchdog?.schedule(deadline: currentTransfer.deadline)
				transfer = nil
			}
		} else {
			transfer = nil
		}
		lock.unlock()

		guard let transfer else { return }
		transfer.task.cancel()
		complete(transfer, result: .failure(CatalogError.timedOut))
	}

	private func cancel() {
		let transfer: Transfer?
		lock.lock()
		if let currentTransfer = self.transfer {
			transfer = takeTransferLocked(for: currentTransfer.task.taskIdentifier)
		} else {
			cancelledBeforeStart = true
			transfer = nil
		}
		lock.unlock()
		transfer?.task.cancel()
		if let transfer {
			complete(transfer, result: .failure(CancellationError()))
		}
	}

	@discardableResult
	private func finish(taskIdentifier: Int, result: Result<URL, Error>) -> Bool {
		guard let transfer = takeTransfer(for: taskIdentifier) else { return false }
		complete(transfer, result: result)
		return true
	}

	private func complete(_ transfer: Transfer, result: Result<URL, Error>) {
		if case .failure = result {
			try? FileManager.default.removeItem(at: transfer.destinationURL)
		}
		transfer.continuation.resume(with: result)
		session?.finishTasksAndInvalidate()
	}
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
	private let httpDownload: CatalogHTTPDownload

	init(
		session: URLSession = .shared,
		fileManager: FileManager = .default,
		httpDownload: @escaping CatalogHTTPDownload = { file, session, onBytesWritten in
			try await CatalogHTTPFileDownloader.download(
				file: file,
				session: session,
				onBytesWritten: onBytesWritten
			)
		}
	) {
		self.session = session
		self.fileManager = fileManager
		self.httpDownload = httpDownload
	}

	func download(
		files: [CatalogFile],
		reportProgress: @escaping @Sendable (CatalogPackageDownloadProgress) -> Void
	) async throws -> URL {
		try await downloadPackage(files: files, reportProgress: reportProgress)
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

	func downloadPackage(
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
				let totalCount = files.count
				for _ in 0..<initialCount {
					let index = nextIndex
					let file = files[index]
					nextIndex += 1
					group.addTask { [session, progressReporter, httpDownload] in
						try await Self.fetch(
							file: file,
							index: index,
							totalCount: totalCount,
							session: session,
							httpDownload: httpDownload
						) { bytesWritten in
							progressReporter.update(file: file, downloadedBytes: bytesWritten)
						}
					}
				}

				while let downloaded = try await group.next() {
					downloadedBytes += downloaded.byteCount
					guard downloadedBytes <= Self.maximumTotalBytes else { throw CatalogError.tooLarge }
					do {
						try stage(downloaded: downloaded, in: stagingRoot)
					} catch {
						// `stage` throws outside `fetch`, so without this line `.invalidFilePath`
						// reaches the user as an anonymous package failure.
						LoggingPolicy.debug(
							Self.stagingFailureLogLine(file: downloaded.file, error: error),
							logger: .networking
						)
						throw error
					}
					progressReporter.complete(file: downloaded.file, downloadedBytes: downloaded.byteCount)

					if nextIndex < files.count {
						let index = nextIndex
						let file = files[index]
						nextIndex += 1
						group.addTask { [session, progressReporter, httpDownload] in
							try await Self.fetch(
								file: file,
								index: index,
								totalCount: totalCount,
								session: session,
								httpDownload: httpDownload
							) { bytesWritten in
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
		if files.count == 1, let file = files.first {
			let lowercasedPath = file.relativePath.lowercased()
			// A standalone Core ML model imports directly; a standalone ONNX graph is converted to
			// Core ML on-device at import time (AIA-0497). Everything else must be a package (below).
			if lowercasedPath.hasSuffix(".mlmodel") || lowercasedPath.hasSuffix(".onnx") {
				return .singleFile(file.relativePath)
			}
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

	// MARK: - Failure reporting (AIA-0602)
	//
	// Until this existed, a failed package download produced exactly one line — "Package download
	// failed: Catalog network request failed" — which names neither the file nor the cause. These
	// lines are what make a support log answer "which file, and why".
	//
	// They are `.debug`, deliberately. `.warning` and `.error` both add a Sentry breadcrumb
	// unconditionally, and `.error` also spends event quota via `captureError` — with three
	// concurrent transfers, one network drop would bill three captures. The ticket requires
	// breadcrumb volume to be unchanged, so per-file reporting stays on the level whose breadcrumb
	// is still `#if DEBUG`-gated.

	nonisolated static func fetch(
		file: CatalogFile,
		index: Int,
		totalCount: Int,
		session: URLSession,
		httpDownload: @escaping CatalogHTTPDownload,
		onBytesWritten: @escaping @Sendable (Int64) -> Void = { _ in }
	) async throws -> DownloadedFile {
		do {
			let temporaryURL = try await httpDownload(file, session, onBytesWritten)
			do {
				let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
				guard let size = values.fileSize else { throw CatalogError.invalidResponse }
				return DownloadedFile(file: file, temporaryURL: temporaryURL, byteCount: Int64(size))
			} catch {
				try? FileManager.default.removeItem(at: temporaryURL)
				throw error
			}
		} catch is CancellationError {
			// A sibling failed and the group cancelled this transfer. Logging it would name files
			// that did not fail, once per concurrent download, and bury the one that did.
			throw CancellationError()
		} catch let error as CatalogError {
			LoggingPolicy.debug(
				transferFailureLogLine(file: file, index: index, totalCount: totalCount, error: error),
				logger: .networking
			)
			throw error
		} catch {
			LoggingPolicy.debug(
				transferFailureLogLine(file: file, index: index, totalCount: totalCount, error: error),
				logger: .networking
			)
			throw CatalogError.network
		}
	}

	func destinationURL(for relativePath: String, in stagingRoot: URL) throws -> URL {
		let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
		guard components.isEmpty == false,
			  components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
			throw CatalogError.invalidFilePath
		}

		// `standardizedFileURL` strips a leading `/private` only when the stripped path exists, so it
		// is not a pure function of the path it is given. Standardising the staging root (which the
		// caller has already created) and the destination (which does not exist yet) separately
		// therefore produced two different prefixes on device, where the temporary directory is
		// `/private/var/mobile/…`: the root became `/var/mobile/…` while the destination kept its
		// `/private`, and containment rejected every download (AIA-0603). Standardise once and derive
		// the destination from that value so the two can never disagree.
		let root = stagingRoot.standardizedFileURL
		let destination = components.reduce(root) { partialResult, component in
			partialResult.appendingPathComponent(String(component))
		}
		// Defence in depth: the component validation above is what rejects `..`, and every component
		// here was derived from `root`, so this cannot currently fail. It stays as a guard against
		// future edits to that validation. Comparing path components rather than a string prefix
		// keeps it from being satisfied by a sibling directory should the derivation ever change.
		let rootComponents = root.pathComponents
		guard destination.pathComponents.count > rootComponents.count,
			  destination.pathComponents.starts(with: rootComponents) else {
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

// MARK: - Log lines the redaction tests assert against

/// Deliberately a **separate, non-private extension** (AIA-0634).
///
/// These five are the only members `CatalogProviderTests` calls, and they were previously declared
/// `internal` inside the `private extension` above — which the compiler warned about on every build
/// ("'internal' modifier conflicts with extension's default access of 'private'") five times over.
/// Deleting the modifier to silence it would have made them private and broken the tests that call
/// them at `CatalogProviderTests.swift:1186-1260`; the fix is to stop declaring them somewhere their
/// visibility has to be argued for. Everything else stays private where it was.
extension CatalogPackageDownloader {
	/// Formats a package-file failure. Every failure line in this file goes through one of these
	/// formatters — transfer, HTTP status, staging — so all three are covered by the same
	/// redaction-survival tests. A hand-built message somewhere else is how one of them quietly stops
	/// surviving redaction while the tests keep passing.
	///
	/// Its shape is load-bearing, because `LogRedactor` runs over this string whenever a user
	/// exports the default (redacted) support log, and two of its patterns would destroy precisely
	/// the part support needs:
	///
	/// - `absolutePathPattern` consumes any run of two or more slash-separated components, so a
	///   package-relative path such as `onnx/data/model.onnx` becomes `onnx[redacted path]`. Only
	///   the last component is safe to log.
	/// - `identifierValuePattern` matches a bare `download`, `entity`, `session` or `user` followed
	///   by `:` or `=` and redacts whatever comes next — so the filename must never sit directly
	///   after one of those words. Hence the em dashes.
	///
	/// `CatalogPackageDownloaderLogTests` runs this function's real output through `LogRedactor` and
	/// asserts the basename and reason survive. Reasoning about those regexes instead of asserting
	/// against them is how this breaks silently.
	/// Asserting on the real emitted string is the only defence here — see the note above.
	internal static func transferFailureLogLine(
		file: CatalogFile,
		index: Int,
		totalCount: Int,
		error: Error
	) -> String {
		"Package file \(index + 1) of \(totalCount) failed — \(safeName(file)) — \(failureReason(for: error))"
	}

	internal static func stagingFailureLogLine(file: CatalogFile, error: Error) -> String {
		"Package staging failed — \(safeName(file)) — \(failureReason(for: error))"
	}

	internal static func failureReason(for error: Error) -> String {
		if let catalogError = error as? CatalogError { return String(describing: catalogError) }
		let nsError = error as NSError
		return "\(nsError.domain) \(nsError.code)"
	}

	/// The basename, with the two characters that can turn it into a `key=value` pair neutralised.
	///
	/// Stripping path components is not enough: `identifierValuePattern` fires on a bare `download`,
	/// `entity`, `session`, `user`… followed by `:` or `=`, and the *filename itself* can supply
	/// both. A catalog file called `download=model.onnx` is rewritten to `download=[redacted]`, and
	/// the release support log stops naming the file it exists to name.
	internal static func safeName(_ file: CatalogFile) -> String {
		(file.relativePath as NSString).lastPathComponent
			.replacingOccurrences(of: "=", with: "_")
			.replacingOccurrences(of: ":", with: "_")
	}

	/// The transport-level line, sharing the formatter so it is covered by the same
	/// redaction-survival tests. Hand-building a second message shape is how one of them silently
	/// stops surviving redaction.
	internal static func httpFailureLogLine(fileName: String?, statusCode: Int) -> String {
		let name = (fileName?.isEmpty == false ? fileName : nil) ?? "unknown"
		let safe = name
			.replacingOccurrences(of: "=", with: "_")
			.replacingOccurrences(of: ":", with: "_")
		return "Package file transfer failed — \(safe) — HTTP \(statusCode)"
	}
}
